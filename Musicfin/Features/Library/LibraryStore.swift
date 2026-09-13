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
    private(set) var recentlyAdded: [MediaItem] = []
    private(set) var frequentlyPlayed: [MediaItem] = []
    private(set) var favoriteTracks: [MediaItem] = []
    /// ライブラリ上部のカードに出す「最後に再生したアルバム」。履歴が無ければ nil。
    private(set) var lastPlayedAlbum: MediaItem?

    private(set) var albumsState: LoadState = .idle
    private(set) var albums: [MediaItem] = []
    private(set) var tracksState: LoadState = .idle
    private(set) var tracks: [MediaItem] = []
    private(set) var artists: [MediaItem] = []
    private(set) var playlists: [MediaItem] = []

    /// アルバム詳細のトラック一覧。アルバム ID をキーにキャッシュする。
    private(set) var tracksByContainer: [String: [MediaItem]] = [:]

    private var client: JellyfinClient?
    private let logger = Logger(subsystem: "jp.qleap.musicfin", category: "LibraryStore")

    /// 全アルバムを取得しきったかどうか。無限スクロールの終端判定に使う。
    private var albumsExhausted = false
    private var tracksExhausted = false
    private let pageSize = 100

    func configure(client: JellyfinClient?) {
        guard self.client != client else { return }
        self.client = client
        reset()
    }

    private func reset() {
        homeState = .idle
        albumsState = .idle
        tracksState = .idle
        recentlyAdded = []
        frequentlyPlayed = []
        favoriteTracks = []
        lastPlayedAlbum = nil
        albums = []
        tracks = []
        artists = []
        playlists = []
        tracksByContainer = [:]
        albumsExhausted = false
        tracksExhausted = false
    }

    // MARK: - ホーム

    func loadHome(force: Bool = false) async {
        guard let client else { return }
        if case .loading = homeState { return }
        if case .loaded = homeState, !force { return }
        homeState = .loading

        do {
            // 各セクションは互いに独立なので同時に取りに行く。
            async let recent = client.fetchRecentlyAdded(limit: 20)
            async let frequent = client.fetchFrequentlyPlayed(limit: 20)
            async let favorites = client.fetchFavoriteTracks(limit: 50)
            // 再生日時の降順で 1 件。未再生でも並びの先頭に来るので、再生回数で実際の履歴か確かめる。
            async let lastPlayed = client.fetchAlbums(limit: 1, sortBy: "DatePlayed", sortOrder: "Descending")

            recentlyAdded = try await recent
            frequentlyPlayed = try await frequent
            favoriteTracks = try await favorites
            lastPlayedAlbum = try await lastPlayed.items.first { ($0.userData?.playCount ?? 0) > 0 }
            homeState = .loaded
        } catch {
            logger.error("ホームの取得に失敗: \(error.localizedDescription, privacy: .public)")
            homeState = .failed(error.localizedDescription)
        }
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
            artists = try await client.fetchAlbumArtists().items
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
        guard let client else { return }
        if case .loading = tracksState { return }
        if force {
            tracks = []
            tracksExhausted = false
        } else if tracksExhausted {
            return
        }
        tracksState = .loading

        do {
            let page = try await client.fetchTracks(startIndex: tracks.count, limit: pageSize)
            tracks.append(contentsOf: page.items)
            tracksExhausted = tracks.count >= page.totalRecordCount || page.items.isEmpty
            tracksState = .loaded
        } catch {
            tracksState = .failed(error.localizedDescription)
        }
    }

    /// 一覧末尾より少し前で次ページを読み、スクロールを止めずに続きを出す。
    func loadMoreTracksIfNeeded(currentItem item: MediaItem) async {
        guard !tracksExhausted, case .loaded = tracksState else { return }
        guard let index = tracks.firstIndex(where: { $0.id == item.id }), index >= tracks.count - 10 else { return }
        await loadTracks()
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
        update(&recentlyAdded)
        update(&frequentlyPlayed)
        update(&favoriteTracks)
        update(&albums)
        update(&tracks)
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
