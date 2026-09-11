import Foundation

@main
struct AlbumCatalogTests {
    @MainActor static func main() async throws {
        let catalog = AlbumCatalog()
        let first = try page(
            """
            {"items":[{"id":"a","genres":["Rock","Jazz"]}],"totalRecordCount":2,"startIndex":0}
            """)
        let second = try page(
            """
            {"items":[{"id":"b","genres":["Rock"," "]}],"totalRecordCount":2,"startIndex":1}
            """)
        await catalog.loadNext { start in
            assert(start == 0)
            return first
        }
        assert(catalog.items.count == 1)
        assert(!catalog.isComplete && catalog.genres.isEmpty)
        enum Failure: Error { case offline }
        await catalog.loadAll { _ in throw Failure.offline }
        assert(catalog.errorMessage != nil && !catalog.isComplete)
        assert(catalog.items.count == 1 && catalog.genres.isEmpty)
        await catalog.loadAll { start in
            assert(start == 1)
            return second
        }
        assert(catalog.isComplete && catalog.errorMessage == nil)
        assert(catalog.genres == ["Jazz", "Rock"])
        assert(catalog.albums(in: "Rock").count == 2)
        assert(catalog.albums(in: "Jazz").map(\.id) == ["a"])
        await catalog.loadNext { _ in fatalError("Completed catalog fetched again") }
        await catalog.refresh { start in
            assert(start == 0)
            return first
        }
        assert(catalog.items.map(\.id) == ["a"] && !catalog.isComplete)
        assert(catalog.genres.isEmpty)
        await catalog.refresh { _ in throw Failure.offline }
        assert(catalog.items.map(\.id) == ["a"] && catalog.errorMessage != nil)
        await catalog.loadAll { start in
            assert(start == 1)
            return second
        }
        assert(catalog.isComplete)
        await catalog.refresh { _ in throw Failure.offline }
        assert(catalog.isComplete && catalog.items.count == 2 && catalog.errorMessage != nil)
        await catalog.refresh { start in
            assert(start == 0)
            return first
        }
        assert(!catalog.isComplete && catalog.items.count == 1 && catalog.errorMessage == nil)
        let empty = AlbumCatalog()
        await empty.loadAll { _ in try page("{\"items\":[],\"totalRecordCount\":0}") }
        assert(empty.isComplete && empty.genres.isEmpty)
        print("AlbumCatalog: pagination, hidden partial genres, retry, grouping, empty and completion passed")
    }

    static func page(_ json: String) throws -> QueryResult<MediaItem> {
        try JSONDecoder().decode(QueryResult<MediaItem>.self, from: Data(json.utf8))
    }
}
