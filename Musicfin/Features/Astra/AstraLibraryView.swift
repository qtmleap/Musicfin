import SwiftUI

enum AstraLibraryRoute: Hashable {
    case albums, artists, playlists, favorites, genres
}

/// 探し方を一階層ずつ選べるよう、五つの入口を単純なリストに揃える。
struct AstraLibraryView: View {
    var body: some View {
        List {
            NavigationLink(value: AstraLibraryRoute.albums) { Label("アルバム", systemImage: "square.stack") }
            NavigationLink(value: AstraLibraryRoute.artists) { Label("アーティスト", systemImage: "music.mic") }
            NavigationLink(value: AstraLibraryRoute.playlists) { Label("プレイリスト", systemImage: "music.note.list") }
            NavigationLink(value: AstraLibraryRoute.favorites) { Label("お気に入りの曲", systemImage: "star") }
            NavigationLink(value: AstraLibraryRoute.genres) { Label("ジャンル", systemImage: "guitars") }
        }
        .listStyle(.plain)
        .navigationTitle("ライブラリ")
        .navigationDestination(for: AstraLibraryRoute.self) { route in
            switch route {
            case .albums: AstraAlbumGridView(title: "アルバム")
            case .artists: AstraLibraryCollectionView(kind: .artists)
            case .playlists: AstraLibraryCollectionView(kind: .playlists)
            case .favorites: AstraFavoriteTracksView()
            case .genres: AstraGenreListView()
            }
        }
    }
}

/// 同じ幅の計算をホームと一覧で共有し、ウインドウのリサイズ時にも列を揃える。
struct AstraAlbumGridMetrics {
    let columns: Int
    let size: CGFloat

    init(width: CGFloat) {
        let available = max(1, width - 32)
        if width < 360 {
            columns = 1
        } else if width < 600 {
            columns = 2
        } else {
            columns = max(3, Int((available + 12) / 192))
        }
        size = max(1, (available - CGFloat(columns - 1) * 12) / CGFloat(columns))
    }

    var gridItems: [GridItem] { Array(repeating: GridItem(.fixed(size), spacing: 12), count: columns) }
}

struct AstraAlbumGridView: View {
    let title: String
    var albums: [MediaItem]?

    @Environment(AuthStore.self) private var auth
    @Environment(AlbumCatalog.self) private var catalog
    @State private var selectedAlbum: MediaItem?

    private var items: [MediaItem] { albums ?? catalog.items }

    var body: some View {
        GeometryReader { geometry in
            let metrics = AstraAlbumGridMetrics(width: geometry.size.width)
            ScrollView {
                LazyVStack(spacing: 0) {
                    LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 24) {
                        ForEach(items) { album in
                            Button {
                                selectedAlbum = album
                            } label: {
                                AstraAlbumCard(item: album, size: metrics.size)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)

                    if albums == nil {
                        if let message = catalog.errorMessage {
                            AstraLibraryLoadError(message: message) { await loadNext() }
                        } else if !catalog.isComplete {
                            ProgressView()
                                .padding()
                                .task(id: catalog.items.count) { await loadNext() }
                        }
                    }
                }
            }
            .overlay {
                if items.isEmpty, albums != nil || catalog.isComplete {
                    ContentUnavailableView("アルバムがありません", systemImage: "square.stack")
                }
            }
        }
        .navigationTitle(title)
        .navigationDestination(item: $selectedAlbum) { AstraAlbumDetailView(album: $0) }
    }

    private func loadNext() async {
        guard let client = auth.client else { return }
        await catalog.loadNext { try await client.fetchAlbums(startIndex: $0) }
    }
}

struct AstraGenreListView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(AlbumCatalog.self) private var catalog

    var body: some View {
        Group {
            if catalog.isComplete {
                if catalog.genres.isEmpty {
                    ContentUnavailableView("ジャンルがありません", systemImage: "guitars")
                } else {
                    List(catalog.genres, id: \.self) { genre in
                        NavigationLink {
                            AstraAlbumGridView(title: genre, albums: catalog.albums(in: genre))
                        } label: {
                            Text(genre)
                        }
                    }
                }
            } else if let message = catalog.errorMessage {
                AstraLibraryLoadError(message: message) { await load() }
            } else {
                ProgressView("すべてのアルバムを確認中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .listStyle(.plain)
        .navigationTitle("ジャンル")
        .task { await load() }
    }

    private func load() async {
        guard let client = auth.client else { return }
        await catalog.loadAll { try await client.fetchAlbums(startIndex: $0) }
    }
}

struct AstraLibraryCollectionView: View {
    enum AstraCollectionKind { case artists, playlists }
    let kind: AstraCollectionKind
    @Environment(AuthStore.self) private var auth
    @State private var isLoading = true
    @State private var items: [MediaItem] = []
    @State private var errorMessage: String?
    private var title: String { kind == .artists ? "アーティスト" : "プレイリスト" }

    var body: some View {
        List(items) { item in
            NavigationLink {
                if kind == .artists { AstraArtistDetailView(artist: item) } else { AstraAlbumDetailView(album: item) }
            } label: {
                if kind == .artists {
                    AstraArtistRow(artist: item)
                } else {
                    HStack(spacing: 12) {
                        ArtworkView(item: item, size: 52, cornerRadius: 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName).foregroundStyle(.primary)
                            Text(item.albumSubtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .overlay {
            if let errorMessage {
                AstraLibraryLoadError(message: errorMessage) { await load() }
            } else if isLoading, items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView("\(title)がありません", systemImage: "music.note.list")
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let client = auth.client else {
            errorMessage = "サーバーに接続してから、もう一度お試しください。"
            return
        }
        do {
            // 失敗と空の一覧を区別するため、エラーを画面で受け取る。
            let result =
                kind == .artists
                ? try await client.fetchAlbumArtists().items
                : try await client.fetchPlaylists().items
            try Task.checkCancellation()
            items = result
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

struct AstraFavoriteTracksView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player

    private var tracks: [MediaItem] { library.favoriteTracks.filter(\.isFavorite) }

    var body: some View {
        List {
            ForEach(tracks) { track in
                Button {
                    if let index = tracks.firstIndex(where: { $0.id == track.id }) {
                        player.play(items: tracks, startingAt: index)
                    }
                } label: {
                    AstraTrackRow(track: track, showsArtwork: true, isPlaying: player.currentItem?.id == track.id)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button {
                        Task { await library.toggleFavorite(track) }
                    } label: {
                        Label("お気に入りから削除", systemImage: "star.slash")
                    }
                    .tint(.yellow)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("お気に入りの曲")
        .overlay {
            if tracks.isEmpty {
                switch library.homeState {
                case .idle, .loading: ProgressView()
                case .failed(let message):
                    AstraLibraryLoadError(message: message) { await library.loadHome(force: true) }
                case .loaded: ContentUnavailableView("お気に入りの曲がありません", systemImage: "star")
                }
            }
        }
        .task { await library.loadHome() }
        .refreshable { await library.loadHome(force: true) }
    }
}

struct AstraLibraryLoadError: View {
    let message: String
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 12) {
            Text("読み込めませんでした").font(.headline)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("再試行") {
                isRetrying = true
                Task {
                    await retry()
                    isRetrying = false
                }
            }
            .buttonStyle(.glass)
            .disabled(isRetrying)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    NavigationStack { AstraLibraryView() }
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
        .environment(PlaybackSettings())
        .environment(AlbumCatalog())
}
