import Foundation

private actor ScopedArtworkServer {
    let bytes: Data
    private(set) var headers: [String?] = []
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(bytes: Data) { self.bytes = bytes }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let header = request.value(forHTTPHeaderField: "Authorization")
        headers.append(header)
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        let status = header == "Fixture A" ? 200 : header == "Fixture B" ? 403 : 401
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

private actor CancellationArtworkServer {
    let bytes: Data
    private(set) var paths: [String] = []
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(bytes: Data) { self.bytes = bytes }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        paths.append(request.url!.path)
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        return (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

private actor RetryingArtworkServer {
    nonisolated enum Outcome: Sendable {
        case http(Int)
        case transport(URLError.Code)
    }

    let bytes: Data
    private var outcomes: [Outcome]
    private(set) var calls = 0

    init(bytes: Data, outcomes: [Outcome]) {
        self.bytes = bytes
        self.outcomes = outcomes
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        try await Task.sleep(for: .milliseconds(20))
        switch outcome {
        case .transport(let code): throw URLError(code)
        case .http(let status):
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

struct ArtworkRequestLifecycleTests {
    static func run(root: URL, bytes: Data) async throws {
        try await authenticationScopes(root: root, bytes: bytes)
        try await cancelledWaiters(root: root, bytes: bytes)
        await sharedRetries(root: root, bytes: bytes)
        print("Artwork requests: authentication isolation, cancelled waiters and shared bounded retries passed")
    }

    private static func authenticationScopes(root: URL, bytes: Data) async throws {
        let url = URL(string: "https://one.example/protected")!
        let first = ArtworkRequest(url: url, authorization: "Fixture A")
        let second = ArtworkRequest(url: url, authorization: "Fixture B")
        let anonymous = ArtworkRequest(url: url)
        assert(Set([first.storageKey, second.storageKey, anonymous.storageKey]).count == 3)
        assert(Set([first.sourceKey, second.sourceKey, anonymous.sourceKey]).count == 3)
        assert(first.storageKey.count == 64 && !first.storageKey.contains("Fixture A"))
        let server = ScopedArtworkServer(bytes: bytes)
        let directory = root.appendingPathComponent("scopes")
        let cache = ArtworkDataStore(directory: directory) { try await server.fetch($0) }
        let firstConsumer = Task { await cache.data(for: first) }
        let sharedConsumer = Task { await cache.data(for: first) }
        let secondConsumer = Task { await cache.data(for: second) }
        let anonymousConsumer = Task { await cache.data(for: anonymous) }
        for _ in 0..<100 {
            if await server.headers.count == 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await server.open()
        let firstResult = await firstConsumer.value
        let sharedResult = await sharedConsumer.value
        let secondResult = await secondConsumer.value
        let anonymousResult = await anonymousConsumer.value
        assert((try? firstResult.get()) == bytes && (try? sharedResult.get()) == bytes)
        assert(failure(secondResult) == .http(403) && failure(anonymousResult) == .http(401))
        let headers = await server.headers
        assert(headers.count == 3 && headers.filter { $0 == "Fixture A" }.count == 1)
        let recreated = ArtworkDataStore(directory: directory) { try await server.fetch($0) }
        let restored = await recreated.data(for: first)
        assert((try? restored.get()) == bytes)
        let rejected = await recreated.data(for: second)
        let unauthenticated = await recreated.data(for: anonymous)
        assert(failure(rejected) == .http(403) && failure(unauthenticated) == .http(401))
        let finalHeaders = await server.headers
        assert(finalHeaders.count == 5, "A disk cache reused artwork from a different authentication scope")
    }

    private static func cancelledWaiters(root: URL, bytes: Data) async throws {
        let server = CancellationArtworkServer(bytes: bytes)
        let cache = ArtworkDataStore(directory: root.appendingPathComponent("cancelled-waiters")) {
            try await server.fetch($0)
        }
        let blockers = (0..<2).map { ArtworkRequest(url: URL(string: "https://one.example/blocker/\($0)")!) }
        let queued = (0..<2).map { ArtworkRequest(url: URL(string: "https://one.example/cancelled/\($0)")!) }
        let first = Task { await cache.prefetch(blockers) }
        for _ in 0..<100 {
            if await server.paths.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let blockedPaths = await server.paths
        assert(blockedPaths.count == 2)
        let abandoned = Task { await cache.prefetch(queued) }
        // 二つ目の一覧が枠待ちへ入った後、枠解放と取消通知が競合する順番で進める。
        try await Task.sleep(for: .milliseconds(30))
        abandoned.cancel()
        await server.open()
        await first.value
        await abandoned.value
        let finalPaths = await server.paths
        assert(finalPaths.count == 2, "Cancelled queued prefetch requests still started network work")
        let retried = await cache.data(for: queued[0])
        assert((try? retried.get()) == bytes, "An abandoned waiter poisoned a later visible request")
    }

    private static func sharedRetries(root: URL, bytes: Data) async {
        let request = ArtworkRequest(url: URL(string: "https://one.example/retry-shared")!)
        let server = RetryingArtworkServer(bytes: bytes, outcomes: [.http(503), .http(200)])
        let cache = ArtworkDataStore(directory: root.appendingPathComponent("shared-retry")) {
            try await server.fetch($0)
        }
        let image = Task { await cache.data(for: request) }
        let backdrop = Task { await cache.data(for: request) }
        let imageResult = await image.value
        let backdropResult = await backdrop.value
        assert((try? imageResult.get()) == bytes && (try? backdropResult.get()) == bytes)
        let calls = await server.calls
        assert(calls == 2, "All consumers must receive the success from one shared retry sequence")
        for status in [401, 403, 404, 503] {
            let permanent = RetryingArtworkServer(bytes: bytes, outcomes: [.http(status)])
            let isolated = ArtworkDataStore(directory: root.appendingPathComponent("failure-\(status)")) {
                try await permanent.fetch($0)
            }
            let result = await isolated.data(for: request)
            assert(failure(result) == .http(status))
            let attempts = await permanent.calls
            assert(attempts == (status == 503 ? 3 : 1), "Retry policy ignored permanent failures or its limit")
        }
        let transient = RetryingArtworkServer(bytes: bytes, outcomes: [.transport(.timedOut), .http(200)])
        let transientCache = ArtworkDataStore(directory: root.appendingPathComponent("network-retry")) {
            try await transient.fetch($0)
        }
        let recovered = await transientCache.data(for: request)
        assert((try? recovered.get()) == bytes)
        let transientCalls = await transient.calls
        assert(transientCalls == 2, "A transient transport failure was not retried")
    }

    private static func failure(_ result: Result<Data, ArtworkFailure>) -> ArtworkFailure? {
        if case .failure(let value) = result { return value }
        return nil
    }
}
