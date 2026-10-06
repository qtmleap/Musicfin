import Foundation

@main
struct MediaPageCollectionTests {
    @MainActor static func main() async throws {
        let history = LibraryFeed.recentlyPlayedTracks.query(userID: "user", startIndex: 20)
        assert(history["includeItemTypes"] == "Audio" && history["sortBy"] == "DatePlayed")
        assert(history["filters"] == "IsPlayed" && history["startIndex"] == "20")
        let recent = LibraryFeed.recentlyAdded.query(userID: "user", startIndex: 40)
        assert(recent["sortBy"] == "DateCreated" && recent["sortOrder"] == "Descending")
        assert(LibraryFeed.tracks.query(userID: "user", startIndex: 100)["limit"] == "100")
        let collection = MediaPageCollection()
        var offsets: [Int] = []
        for _ in 0..<3 {
            await collection.loadNext { offset in
                offsets.append(offset)
                let end = min(offset + 100, 250)
                let entries = (offset..<end).map { "{\"id\":\"\($0)\"}" }.joined(separator: ",")
                return try decode("{\"items\":[\(entries)],\"totalRecordCount\":250}")
            }
        }
        assert(offsets == [0, 100, 200])
        assert(collection.items.count == 250 && collection.isComplete)
        await collection.loadNext { _ in fatalError("Fetched past end") }
        await collection.refresh { _ in try decode("{\"items\":[{\"id\":\"a\"}],\"totalRecordCount\":4}") }
        await collection.loadNext { offset in
            assert(offset == 1)
            return try decode("{\"items\":[{\"id\":\"a\"},{\"id\":\"b\"}],\"totalRecordCount\":4}")
        }
        enum Failure: Error { case offline }
        await collection.loadNext { offset in
            assert(offset == 3)
            throw Failure.offline
        }
        assert(collection.items.map(\.id) == ["a", "b"] && collection.errorMessage != nil)
        await collection.loadNext { offset in
            assert(offset == 3)
            return try decode("{\"items\":[{\"id\":\"c\"}],\"totalRecordCount\":4}")
        }
        assert(collection.isComplete && collection.items.count == 3)
        await collection.refresh { _ in throw Failure.offline }
        assert(collection.items.count == 3 && collection.isComplete)
        await collection.loadNext { offset in
            assert(offset == 0)
            return try decode("{\"items\":[{\"id\":\"refreshed\"}],\"totalRecordCount\":1}")
        }
        assert(collection.items.map(\.id) == ["refreshed"] && collection.errorMessage == nil)
        await collection.refresh { _ in
            collection.reset()
            return try decode("{\"items\":[{\"id\":\"stale\"}],\"totalRecordCount\":1}")
        }
        assert(collection.items.isEmpty && !collection.isLoading && !collection.isComplete)
        await collection.loadNext { _ in
            await collection.loadNext { _ in fatalError("Duplicate concurrent request") }
            throw CancellationError()
        }
        assert(collection.errorMessage == nil && collection.items.isEmpty)
        await collection.loadNext { _ in try decode("{\"items\":[{\"id\":\"a\"}],\"totalRecordCount\":10}") }
        let revision = collection.revision
        for offset in 1...3 {
            await collection.loadNext { start in
                assert(start == offset)
                return try decode("{\"items\":[{\"id\":\"a\"}],\"totalRecordCount\":10}")
            }
        }
        assert(collection.items.count == 1 && collection.revision == revision + 3)
        assert(!collection.isComplete && collection.needsManualContinuation)
        collection.reset()
        await collection.loadNext { _ in
            let cancelled = Task { @MainActor in
                await collection.refresh { _ in fatalError("Cancelled refresh fetched") }
            }
            cancelled.cancel()
            await cancelled.value
            return try decode("{\"items\":[{\"id\":\"active\"}],\"totalRecordCount\":1}")
        }
        assert(collection.items.map(\.id) == ["active"] && !collection.isLoading)
        print(
            "MediaPageCollection: 250 items, raw offsets, deduplication, retry, refresh, invalidation and cancellation passed"
        )
    }

    static func decode(_ json: String) throws -> QueryResult<MediaItem> {
        try JSONDecoder().decode(QueryResult<MediaItem>.self, from: Data(json.utf8))
    }
}
