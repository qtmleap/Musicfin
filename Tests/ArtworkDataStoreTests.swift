import Foundation

private actor ArtworkServer {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var peak = 0
    var status = 200
    let bytes: Data

    init(bytes: Data) { self.bytes = bytes }
    func setStatus(_ value: Int) { status = value }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (bytes, response)
    }
}

private actor GatedArtworkServer {
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

@main
struct ArtworkDataStoreTests {
    static func main() async throws {
        try ArtworkImageDecoderTests.run()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=")!
        let request = ArtworkRequest(
            url: URL(string: "https://one.example/Items/a/Images/Primary?maxWidth=144&maxHeight=144&tag=v1")!)
        let sameBucket = ArtworkRequest(
            url: URL(string: "https://one.example/Items/a/Images/Primary?maxWidth=192&maxHeight=192&tag=v1")!)
        assert(request.url == sameBucket.url, "Row sizes must share a network and disk key")
        let enlarged = ArtworkRequest(
            url: URL(string: "https://one.example/Items/a/Images/Primary?maxWidth=1500&maxHeight=1500&tag=v1")!)
        assert(
            request.sourceKey == enlarged.sourceKey && request.url != enlarged.url,
            "Resolution changes must preserve the currently displayed artwork until the replacement arrives")
        let server = ArtworkServer(bytes: bytes)
        let directory = root.appendingPathComponent("shared")
        let cache = ArtworkDataStore(directory: directory, transport: { try await server.fetch($0) })
        let images = await withTaskGroup(of: Result<Data, ArtworkFailure>.self) { group in
            for _ in 0..<10 { group.addTask { await cache.data(for: request) } }
            var found: [Result<Data, ArtworkFailure>] = []
            for await image in group { found.append(image) }
            return found
        }
        assert(images.allSatisfy { (try? $0.get()) == bytes })
        let calls = await server.calls
        assert(calls == 1, "Concurrent consumers downloaded the same artwork repeatedly")

        let recreated = ArtworkDataStore(directory: directory, transport: { try await server.fetch($0) })
        let restored = await recreated.data(for: request)
        assert((try? restored.get()) == bytes)
        let restoredCalls = await server.calls
        assert(restoredCalls == 1, "A new cache instance did not reuse the stored image")

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try Data("broken image".utf8).write(to: files[0], options: .atomic)
        let repaired = await recreated.data(for: request)
        assert((try? repaired.get()) == bytes)
        let repairedCalls = await server.calls
        assert(repairedCalls == 2, "A corrupt disk entry was not fetched again")

        let version = ArtworkRequest(
            url: URL(string: "https://one.example/Items/a/Images/Primary?maxWidth=144&maxHeight=144&tag=v2")!)
        let otherServer = ArtworkRequest(
            url: URL(string: "https://two.example/Items/a/Images/Primary?maxWidth=144&maxHeight=144&tag=v1")!)
        _ = await recreated.data(for: version)
        _ = await recreated.data(for: otherServer)
        let separatedCalls = await server.calls
        assert(separatedCalls == 4, "Changed image tags and servers must not share old bytes")

        let retryRequest = ArtworkRequest(url: URL(string: "https://one.example/retry")!)
        await server.setStatus(503)
        let failed = await recreated.data(for: retryRequest)
        assert(failed.failure?.isRetryable == true)
        await server.setStatus(200)
        let retried = await recreated.data(for: retryRequest)
        assert((try? retried.get()) == bytes, "A transient failure poisoned subsequent requests")
        await server.setStatus(404)
        let missing = await recreated.data(for: ArtworkRequest(url: URL(string: "https://one.example/missing")!))
        assert(missing.failure?.isRetryable == false)
        await server.setStatus(200)

        let invalid = ArtworkDataStore(directory: root.appendingPathComponent("invalid")) { request in
            (
                Data("not an image".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let invalidResult = await invalid.data(for: request)
        assert(invalidResult.failure == .invalidImage, "Invalid bytes were accepted as a successful image")

        let small = ArtworkDataStore(directory: root.appendingPathComponent("limited"), byteLimit: bytes.count + 1) {
            try await server.fetch($0)
        }
        _ = await small.data(for: request)
        _ = await small.data(for: version)
        let stored = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("limited"), includingPropertiesForKeys: [.fileSizeKey])
        let diskBytes = try stored.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        assert(diskBytes <= bytes.count + 1, "The persistent cache exceeded its configured budget")
        let gate = GatedArtworkServer(bytes: bytes)
        let priorityCache = ArtworkDataStore(directory: root.appendingPathComponent("priority")) {
            try await gate.fetch($0)
        }
        let backgroundRequests = (0..<8).map {
            ArtworkRequest(url: URL(string: "https://one.example/background/\($0)")!)
        }
        let prefetch = Task { await priorityCache.prefetch(backgroundRequests) }
        for _ in 0..<100 {
            if await gate.paths.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let initialPaths = await gate.paths
        assert(initialPaths.count == 2, "Prefetch must use at most two requests")
        let visibleRequest = ArtworkRequest(url: URL(string: "https://one.example/visible")!)
        let visible = Task { await priorityCache.data(for: visibleRequest) }
        for _ in 0..<100 {
            if await gate.paths.contains("/visible") { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let beforeRelease = await gate.paths
        assert(
            beforeRelease == ["/background/0", "/background/1", "/visible"]
                || beforeRelease == ["/background/1", "/background/0", "/visible"],
            "A displayed image waited for all prefetch work")
        prefetch.cancel()
        let shared = Task { await priorityCache.data(for: backgroundRequests[0]) }
        await gate.open()
        let sharedResult = await shared.value
        let visibleResult = await visible.value
        await prefetch.value
        assert(
            (try? sharedResult.get()) == bytes && (try? visibleResult.get()) == bytes,
            "Cancelling prefetch destroyed a shared displayed request")
        let finalPaths = await gate.paths
        assert(finalPaths.count == 3, "Cancelled prefetch kept starting offscreen requests")
        try await ArtworkRequestLifecycleTests.run(root: root, bytes: bytes)
        print(
            "ArtworkDataStore: persistence, recovery, bounded prefetch, foreground priority and shared cancellation passed"
        )
    }
}

nonisolated extension Result where Failure == ArtworkFailure {
    fileprivate var failure: ArtworkFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
