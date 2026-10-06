import Foundation

@main
struct RadioMixCatalogTests {
    @MainActor static func main() async throws {
        let catalog = RadioMixCatalog()
        let seeds = try page("{\"items\":[{\"id\":\"s1\"},{\"id\":\"s2\"},{\"id\":\"s3\"}],\"totalRecordCount\":3}")
        let a = try page("{\"items\":[{\"id\":\"a\",\"type\":\"Audio\"}],\"totalRecordCount\":1}").items
        let b = try page("{\"items\":[{\"id\":\"b\",\"type\":\"Audio\"}],\"totalRecordCount\":1}").items
        var requested: [String] = []
        await catalog.loadNext(
            preferredSeed: nil, fetchSeeds: { _ in seeds },
            fetchMix: {
                requested.append($0)
                return a
            })
        enum Failure: Error { case offline }
        await catalog.loadNext(
            preferredSeed: nil, fetchSeeds: { _ in fatalError() },
            fetchMix: {
                requested.append($0)
                throw Failure.offline
            })
        assert(catalog.items.count == 1 && catalog.errorMessage != nil)
        await catalog.loadNext(
            preferredSeed: nil, fetchSeeds: { _ in fatalError() },
            fetchMix: {
                requested.append($0)
                return $0 == "s2" ? a : a + b
            })
        assert(requested == ["s1", "s2", "s2", "s3"])
        assert(catalog.items.map(\.id) == ["a", "b"])
        await catalog.loadNext(preferredSeed: nil, fetchSeeds: { _ in fatalError() }, fetchMix: { _ in fatalError() })
        assert(catalog.isComplete)
        catalog.reset()
        await catalog.loadNext(
            preferredSeed: nil, fetchSeeds: { _ in seeds },
            fetchMix: { _ in
                catalog.reset()
                return a
            })
        assert(catalog.items.isEmpty && !catalog.isLoading)
        catalog.reset()
        let moreSeeds = try page(
            "{\"items\":[{\"id\":\"s1\"},{\"id\":\"s2\"},{\"id\":\"s3\"},{\"id\":\"s4\"}],\"totalRecordCount\":4}")
        await catalog.loadNext(preferredSeed: nil, fetchSeeds: { _ in moreSeeds }, fetchMix: { _ in [] })
        assert(catalog.items.isEmpty && catalog.needsManualContinuation && !catalog.isComplete)
        await catalog.loadNext(
            preferredSeed: nil, fetchSeeds: { _ in fatalError() },
            fetchMix: { seed in
                assert(seed == "s4")
                return a
            })
        assert(catalog.items.map(\.id) == ["a"])
        print(
            "RadioMixCatalog: different seeds, deduplication, failed seed retry, exhaustion and stale response passed")
    }
    static func page(_ json: String) throws -> QueryResult<MediaItem> {
        try JSONDecoder().decode(QueryResult<MediaItem>.self, from: Data(json.utf8))
    }
}
