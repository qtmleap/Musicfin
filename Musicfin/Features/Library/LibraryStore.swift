import Foundation
import Observation
import os

/// ライブラリの取得結果を保持し、画面から使いやすい形で公開する。
@MainActor
@Observable
final class LibraryStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var homeState: LoadState = .idle
    private let pages = Dictionary(uniqueKeysWithValues: LibraryFeed.allCases.map { ($0, MediaPageCollection()) })
    var recentlyAdded: [MediaItem] { page(for: .recentlyAdded).items }
    var frequentlyPlayed: [MediaItem] { page(for: .frequentlyPlayed).items }
    var favoriteTracks: [MediaItem] { page(for: .favoriteTracks).items }
    var recentlyPlayedAlbums: [MediaItem] { page(for: .recentlyPlayedAlbums).items }
    var recentlyPlayedTracks: [MediaItem] { page(for: .recentlyPlayedTracks).items }
    /// ライブラリ上部のカードに出す「最後に再生したアルバム」。履歴が無ければ nil。
    private(set) var lastPlayedAlbum: MediaItem?

    private(set) var albumsState: LoadState = .idle
    private(set) var albums: [MediaItem] = []
    var tracksState: LoadState {
        let page = page(for: .tracks)
        if page.isLoading { return .loading }
        if let error = page.errorMessage { return .failed(error) }
        return page.hasLoaded ? .loaded : .idle
    }
    var tracks: [MediaItem] { page(for: .tracks).items }
    private(set) var artists: [MediaItem] = []
    private(set) var playlists: [MediaItem] = []

    /// アルバム詳細のトラック一覧。アルバム ID をキーにキャッシュする。
    private(set) var tracksByContainer: [String: [MediaItem]] = [:]

    private var homeGeneration = 0
    private var client: JellyfinClient?
    private let logger = Logger(subsystem: "jp.qleap.musicfin", category: "LibraryStore")

    /// 全アルバムを取得しきったかどうか。無限スクロールの終端判定に使う。
    private var albumsExhausted = false
    private let pageSize = 100

    func configure(client: JellyfinClient?) {
        guard self.client != client else { return }
        self.client = client
        reset()
    }

    private func reset() {
        homeGeneration += 1
        homeState = .idle
        albumsState = .idle
        for page in pages.values { page.reset() }
        lastPlayedAlbum = nil
        albums = []
        artists = []
        playlists = []
        tracksByContainer = [:]
        albumsExhausted = false
    }

    // MARK: - ホーム

    func page(for feed: LibraryFeed) -> MediaPageCollection { pages[feed]! }

    func loadFeed(_ feed: LibraryFeed, force: Bool = false) async {
        guard let client, let userID = client.userID else { return }
        let page = page(for: feed)
        let fetch: (Int) async throws -> QueryResult<MediaItem> = { offset in
            try await client.get("/Items", query: feed.query(userID: userID, startIndex: offset))
        }
        if force { await page.refresh(fetch: fetch) } else { await page.loadNext(fetch: fetch) }
    }

    func loadHome(force: Bool = false) async {
        guard let client else { return }
        if case .loading = homeState { return }
        if case .loaded = homeState, !force { return }
        let generation = homeGeneration
        homeState = .loading
        async let recent: Void = loadFeed(.recentlyAdded, force: force)
        async let frequent: Void = loadFeed(.frequentlyPlayed, force: force)
        async let favorites: Void = loadFeed(.favoriteTracks, force: force)
        async let albums: Void = loadFeed(.recentlyPlayedAlbums, force: force)
        async let tracks: Void = loadFeed(.recentlyPlayedTracks, force: force)
        _ = await (recent, frequent, favorites, albums, tracks)
        guard self.client == client, generation == homeGeneration else { return }
        lastPlayedAlbum = recentlyPlayedAlbums.first
        let error = LibraryFeed.allCases.filter { $0 != .tracks }.compactMap { page(for: $0).errorMessage }.first
        let initialized = LibraryFeed.allCases.filter { $0 != .tracks }.allSatisfy { page(for: $0).hasLoaded }
        homeState = error.map { .failed($0) } ?? (initialized ? .loaded : .idle)
    }

    // MARK: - アルバム / アーティスト / プレイリスト

    func loadAlbums(force: Bool = false) async {
        guard let client else { return }
        if case .loading = albumsState { return }
        if case .loaded = albumsState, !force { return }
        if force {
            albums = []
            albumsExhausted = false
        }
        albumsState = .loading

        do {
            let page = try await client.fetchAlbums(startIndex: albums.count, limit: pageSize)
            albums.append(contentsOf: page.items)
            albumsExhausted = albums.count >= page.totalRecordCount || page.items.isEmpty
            albumsState = .loaded
        } catch {
            albumsState = .failed(error.localizedDescription)
        }
    }

    /// 一覧の末尾が見えたときに呼ぶ。読み込み済みなら何もしない。
    func loadMoreAlbumsIfNeeded(currentItem item: MediaItem) async {
        guard !albumsExhausted, case .loaded = albumsState else { return }
        // 末尾から 10 件以内に入ったら次のページを取りに行く。
        guard let index = albums.firstIndex(where: { $0.id == item.id }),
            index >= albums.count - 10
        else { return }
        await loadAlbums()
    }

    func loadArtists() async {
        guard let client, artists.isEmpty else { return }
        do {
            var loaded: [MediaItem] = []
            var total = 1
            while loaded.count < total {
                let page = try await client.fetchAlbumArtists(startIndex: loaded.count)
                loaded.append(contentsOf: page.items)
                total = page.totalRecordCount
                if page.items.isEmpty { break }
            }
            artists = loaded
        } catch {
            logger.error("アーティストの取得に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadPlaylists() async {
        guard let client, playlists.isEmpty else { return }
        do {
            playlists = try await client.fetchPlaylists().items
        } catch {
            logger.error("プレイリストの取得に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - トラック

    func loadTracks(force: Bool = false) async {
        await loadFeed(.tracks, force: force)
    }

    /// アルバムまたはプレイリストの収録曲。取得済みならキャッシュを返す。
    @discardableResult
    func tracks(for container: MediaItem) async -> [MediaItem] {
        if let cached = tracksByContainer[container.id] { return cached }
        guard let client else { return [] }
        do {
            let result =
                container.type == .playlist
                ? try await client.fetchTracks(inPlaylist: container.id)
                : try await client.fetchTracks(inAlbum: container.id)
            // プレイリストは取得順がそのまま並び順なので触らない（仕様 8 章）。
            let items = container.type == .playlist ? result.items : sortedAlbumTracks(result.items)
            tracksByContainer[container.id] = items
            return items
        } catch {
            logger.error("トラックの取得に失敗: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// アルバムの収録曲をディスク→トラック番号→曲名で並べ直す。
    /// 問い合わせには `sortBy` を付けているが、それに従わないサーバーがあるので受け取った側でも整える。
    /// 番号のない曲は同じディスクの末尾へ送る。先頭に来ると番号の付いた曲を押しのけてしまう。
    private func sortedAlbumTracks(_ items: [MediaItem]) -> [MediaItem] {
        let missing = items.count { $0.indexNumber == nil }
        if missing > 0 {
            logger.debug("アルバムのトラック番号が未設定: \(missing, privacy: .public)/\(items.count, privacy: .public) 曲")
        }
        return items.sorted { lhs, rhs in
            let leftDisc = lhs.parentIndexNumber ?? 1
            let rightDisc = rhs.parentIndexNumber ?? 1
            if leftDisc != rightDisc { return leftDisc < rightDisc }
            let leftIndex = lhs.indexNumber ?? .max
            let rightIndex = rhs.indexNumber ?? .max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// 一覧に出ているアルバムの収録曲を、一覧の並び順のままつなげて返す。
    /// 1 アルバム 1 リクエストになるので、サーバーを詰まらせないよう同時実行を絞る。
    func tracks(forAll containers: [MediaItem]) async -> [MediaItem] {
        var result: [MediaItem] = []
        for start in stride(from: 0, to: containers.count, by: 6) {
            let chunk = Array(containers[start..<min(start + 6, containers.count)])
            let fetched = await withTaskGroup(
                of: IndexedTracks.self, returning: [IndexedTracks].self
            ) { group in
                for index in chunk.indices {
                    let container = chunk[index]
                    group.addTask {
                        await IndexedTracks(index: index, tracks: self.tracks(for: container))
                    }
                }
                var items: [IndexedTracks] = []
                for await item in group { items.append(item) }
                return items
            }
            // 完了順に返るので、一覧の並びへ戻してからつなげる。
            result += fetched.sorted { $0.index < $1.index }.flatMap(\.tracks)
        }
        return result
    }

    func albums(byArtist artist: MediaItem) async -> [MediaItem] {
        guard let client else { return [] }
        return (try? await client.fetchAlbums(byArtist: artist.id).items) ?? []
    }

    // MARK: - お気に入り

    /// 楽観的に UI を更新してからサーバーに送る。失敗したら元に戻す。
    func toggleFavorite(_ item: MediaItem) async {
        guard let client else { return }
        let newValue = !item.isFavorite
        applyFavorite(newValue, to: item.id)
        do {
            try await client.setFavorite(newValue, itemID: item.id)
        } catch {
            applyFavorite(!newValue, to: item.id)
            logger.error("お気に入りの更新に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyFavorite(_ value: Bool, to itemID: String) {
        func update(_ items: inout [MediaItem]) {
            guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
            var data = items[index].userData ?? UserItemData()
            data.isFavorite = value
            items[index].userData = data
        }
        for page in pages.values { page.updateFavorite(value, itemID: itemID) }
        update(&albums)
        for key in tracksByContainer.keys {
            update(&tracksByContainer[key]!)
        }
    }
}

/// 並列取得の結果を一覧の並びへ戻すための添字付きの箱。
/// タスクグループの外へ渡るので `MainActor` から切り離しておく。
private nonisolated struct IndexedTracks: Sendable {
    let index: Int
    let tracks: [MediaItem]
}
