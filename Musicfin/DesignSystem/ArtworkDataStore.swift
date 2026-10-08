import Foundation
import ImageIO

/// HTTP キャッシュの保存判断へ依存せず、検証できた画像だけを容量制限付きで保持する。
actor ArtworkDataStore {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    nonisolated enum Priority: Sendable { case visible, prefetch }

    static let shared = ArtworkDataStore(
        directory: URL.cachesDirectory.appendingPathComponent("MusicfinArtwork", isDirectory: true))

    private let directory: URL
    private let byteLimit: Int
    private let transport: Transport
    private var inFlight: [String: Flight] = [:]
    private var activeFlights: Set<UUID> = []
    private var active = 0
    private var activePrefetch = 0
    private var waiting: [Waiter] = []
    private var entries: [String: Entry]?

    private nonisolated struct Entry {
        let bytes: Int
        var touched: Date
    }
    private nonisolated struct Waiter {
        let key: String
        let flightID: UUID
        var priority: Priority
        let continuation: CheckedContinuation<Priority?, Never>
    }

    private nonisolated struct Flight {
        let id: UUID
        let task: Task<Result<Data, ArtworkFailure>, Never>
        var priority: Priority
        var consumers: [UUID: Consumer]
    }

    /// 枠解放より actor への取消通知が遅れても、未着手の要求を開始しないため同期して印を付ける。
    private nonisolated final class Consumer: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    init(
        directory: URL,
        byteLimit: Int = 512 * 1024 * 1024,
        transport: @escaping Transport = ArtworkDataStore.fetch
    ) {
        self.directory = directory
        self.byteLimit = max(0, byteLimit)
        self.transport = transport
    }

    func data(for request: ArtworkRequest, priority: Priority = .visible) async -> Result<Data, ArtworkFailure> {
        guard !Task.isCancelled else { return .failure(.transport(URLError.cancelled.rawValue)) }
        let key = request.storageKey
        if let bytes = read(key: key) { return .success(bytes) }
        let consumer = Consumer()
        let flight: Flight
        if var existing = inFlight[key] {
            existing.consumers[consumer.id] = consumer
            if priority == .visible { existing.priority = .visible }
            inFlight[key] = existing
            flight = existing
            // 表示された画像は、先読みの待ち行列に残さず表示用の枠へ昇格させる。
            if priority == .visible, let index = waiting.firstIndex(where: { $0.flightID == existing.id }) {
                waiting[index].priority = .visible
                drain()
            }
        } else {
            let id = UUID()
            // 開始済みの共有通信は、セルの消失で別の表示まで失敗させないよう独立させる。
            let task = Task(priority: priority == .visible ? .userInitiated : .utility) {
                await download(request, key: key, flightID: id, priority: priority)
            }
            flight = Flight(id: id, task: task, priority: priority, consumers: [consumer.id: consumer])
            inFlight[key] = flight
        }
        let result = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            consumer.cancel()
            Task { await self.cancelConsumer(key: key, flightID: flight.id, consumerID: consumer.id) }
        }
        if inFlight[key]?.id == flight.id { inFlight[key] = nil }
        return result
    }

    private func cancelConsumer(key: String, flightID: UUID, consumerID: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.consumers[consumerID] = nil
        inFlight[key] = flight
        guard !activeFlights.contains(flightID), !hasConsumers(key: key, flightID: flightID) else { return }
        inFlight[key] = nil
        flight.task.cancel()
        if let index = waiting.firstIndex(where: { $0.flightID == flightID }) {
            waiting.remove(at: index).continuation.resume(returning: nil)
        }
        drain()
    }

    private func hasConsumers(key: String, flightID: UUID) -> Bool {
        guard let flight = inFlight[key], flight.id == flightID else { return false }
        return flight.consumers.values.contains { !$0.isCancelled }
    }

    /// 待ち手も 2 件までに絞り、一覧変更時は未着手分を捨てる。共有中の通信は取り消さない。
    func prefetch(_ requests: [ArtworkRequest]) async {
        var seen: Set<String> = []
        let unique = requests.filter { seen.insert($0.storageKey).inserted }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                guard next < unique.count, !Task.isCancelled else { return }
                let request = unique[next]
                next += 1
                group.addTask { _ = await self.data(for: request, priority: .prefetch) }
            }
            enqueue()
            enqueue()
            while await group.next() != nil { enqueue() }
        }
    }

    private func download(_ request: ArtworkRequest, key: String, flightID: UUID, priority: Priority) async -> Result<
        Data, ArtworkFailure
    > {
        guard let acquired = await acquire(key: key, flightID: flightID, priority: priority) else {
            return .failure(.transport(URLError.cancelled.rawValue))
        }
        defer {
            active -= 1
            activeFlights.remove(flightID)
            if acquired == .prefetch { activePrefetch -= 1 }
            drain()
        }
        for attempt in 0..<3 {
            let result = await fetchOnce(request)
            switch result {
            case .success(let data):
                write(data, key: key)
                return result
            case .failure(let failure):
                // 画像と背景の待ち手へ同じ回復結果を返す。恒久エラーは繰り返さない。
                guard failure.isRetryable, attempt < 2 else { return result }
                do { try await Task.sleep(for: .milliseconds(attempt == 0 ? 500 : 1500)) } catch {
                    return .failure(.transport(URLError.cancelled.rawValue))
                }
            }
        }
        return .failure(.transport(URLError.unknown.rawValue))
    }

    private func fetchOnce(_ request: ArtworkRequest) async -> Result<Data, ArtworkFailure> {
        do {
            let (data, response) = try await transport(request.urlRequest)
            guard let response = response as? HTTPURLResponse else {
                return .failure(.transport(URLError.badServerResponse.rawValue))
            }
            guard (200..<300).contains(response.statusCode) else { return .failure(.http(response.statusCode)) }
            guard Self.isImage(data) else { return .failure(.invalidImage) }
            return .success(data)
        } catch {
            return .failure(.transport((error as NSError).code))
        }
    }

    private func acquire(key: String, flightID: UUID, priority: Priority) async -> Priority? {
        guard !Task.isCancelled, hasConsumers(key: key, flightID: flightID) else {
            if inFlight[key]?.id == flightID { inFlight[key] = nil }
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiting.append(
                Waiter(
                    key: key, flightID: flightID, priority: inFlight[key]?.priority ?? priority,
                    continuation: continuation))
            drain()
        }
    }

    private func drain() {
        // 取消ハンドラの actor 呼び出しを待たず、枠を渡す直前にも利用者を確かめる。
        for index in waiting.indices.reversed() {
            let waiter = waiting[index]
            if !hasConsumers(key: waiter.key, flightID: waiter.flightID) {
                discard(waiting.remove(at: index))
            }
        }
        while active < 4 {
            let next =
                waiting.firstIndex { $0.priority == .visible }
                ?? (activePrefetch < 2 ? waiting.firstIndex { $0.priority == .prefetch } : nil)
            guard let next else { return }
            let waiter = waiting.remove(at: next)
            guard hasConsumers(key: waiter.key, flightID: waiter.flightID) else {
                discard(waiter)
                continue
            }
            active += 1
            activeFlights.insert(waiter.flightID)
            if waiter.priority == .prefetch { activePrefetch += 1 }
            waiter.continuation.resume(returning: waiter.priority)
        }
    }

    private func discard(_ waiter: Waiter) {
        if let flight = inFlight[waiter.key], flight.id == waiter.flightID {
            flight.task.cancel()
            inFlight[waiter.key] = nil
        }
        waiter.continuation.resume(returning: nil)
    }

    private func loadIndex() {
        guard entries == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var found: [String: Entry] = [:]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "artwork" {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            found[file.deletingPathExtension().lastPathComponent] = Entry(
                bytes: values.fileSize ?? 0, touched: values.contentModificationDate ?? .distantPast)
        }
        entries = found
        trim()
    }

    private func file(for key: String) -> URL { directory.appendingPathComponent(key + ".artwork") }

    private func read(key: String) -> Data? {
        loadIndex()
        guard entries?[key] != nil else { return nil }
        let path = file(for: key)
        guard let bytes = try? Data(contentsOf: path, options: .mappedIfSafe), Self.isImage(bytes) else {
            entries?[key] = nil
            try? FileManager.default.removeItem(at: path)
            return nil
        }
        let now = Date()
        entries?[key]?.touched = now
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
        return bytes
    }

    private func write(_ data: Data, key: String) {
        loadIndex()
        guard data.count <= byteLimit else { return }
        do {
            try data.write(to: file(for: key), options: .atomic)
            entries?[key] = Entry(bytes: data.count, touched: Date())
            trim()
        } catch {
            // 保存できなくても今回の表示は成功させ、次の要求で取得し直せるようにする。
        }
    }

    private func trim() {
        guard let entries else { return }
        var total = entries.values.reduce(0) { $0 + $1.bytes }
        for (key, entry) in entries.sorted(by: { $0.value.touched < $1.value.touched }) {
            guard total > byteLimit else { break }
            try? FileManager.default.removeItem(at: file(for: key))
            self.entries?[key] = nil
            total -= entry.bytes
        }
    }

    private nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
    }

    private nonisolated static let session: URLSession = {
        // ディスクは上の保存先だけが持ち、URLCache と同じ画像を二重に保存しない。
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private nonisolated static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
