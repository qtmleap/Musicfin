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

    private(set) var albumsState: LoadState = .idle
    private(set) var albums: [MediaItem] = []
    private(set) var artists: [MediaItem] = []
    private(set) var playlists: [MediaItem] = []

    /// アルバム詳細のトラック一覧。アルバム ID をキーにキャッシュする。
    private(set) var tracksByContainer: [String: [MediaItem]] = [:]

    private var client: JellyfinClient?
    private let logger = Logger(subsystem: "am.nasawake.Musicfin", category: "LibraryStore")

    /// 全アルバムを取得しきったかどうか。無限スクロールの終端判定に使う。
    private var albumsExhausted = false
    private let pageSize = 100

    func configure(client: JellyfinClient?) {
        guard self.client != client else { return }
        self.client = client
        reset()
    }

    private func reset() {
        homeState = .idle
        albumsState = .idle
        recentlyAdded = []
        frequentlyPlayed = []
        favoriteTracks = []
        albums = []
        artists = []
        playlists = []
        tracksByContainer = [:]
        albumsExhausted = false
    }

    // MARK: - ホーム

    func loadHome(force: Bool = false) async {
        guard let client else { return }
        if case .loading = homeState { return }
        if case .loaded = homeState, !force { return }
        homeState = .loading

        do {
            // 3 つのセクションは互いに独立なので同時に取りに行く。
            async let recent = client.fetchRecentlyAdded(limit: 20)
            async let frequent = client.fetchFrequentlyPlayed(limit: 20)
            async let favorites = client.fetchFavoriteTracks(limit: 50)

            recentlyAdded = try await recent
            frequentlyPlayed = try await frequent
            favoriteTracks = try await favorites
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
        if force { albums = []; albumsExhausted = false }
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

    /// アルバムまたはプレイリストの収録曲。取得済みならキャッシュを返す。
    @discardableResult
    func tracks(for container: MediaItem) async -> [MediaItem] {
        if let cached = tracksByContainer[container.id] { return cached }
        guard let client else { return [] }
        do {
            let result = container.type == .playlist
                ? try await client.fetchTracks(inPlaylist: container.id)
                : try await client.fetchTracks(inAlbum: container.id)
            tracksByContainer[container.id] = result.items
            return result.items
        } catch {
            logger.error("トラックの取得に失敗: \(error.localizedDescription, privacy: .public)")
            return []
        }
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
        for key in tracksByContainer.keys {
            update(&tracksByContainer[key]!)
        }
    }
}
