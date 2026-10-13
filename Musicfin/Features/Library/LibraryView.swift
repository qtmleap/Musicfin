import SwiftUI

enum LibraryRoute: Hashable {
    case albums, artists, playlists, favorites, genres
}

struct LibraryView: View {
    var body: some View {
        List {
            NavigationLink(value: LibraryRoute.albums) { Label("アルバム", systemImage: "square.stack") }
            NavigationLink(value: LibraryRoute.artists) { Label("アーティスト", systemImage: "music.mic") }
            NavigationLink(value: LibraryRoute.playlists) { Label("プレイリスト", systemImage: "music.note.list") }
            NavigationLink(value: LibraryRoute.favorites) { Label("お気に入りの曲", systemImage: "star") }
            NavigationLink(value: LibraryRoute.genres) { Label("ジャンル", systemImage: "guitars") }
        }
        .navigationTitle("ライブラリ")
        .navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .albums: AlbumGridView(title: "アルバム")
            case .artists: LibraryCollectionView(kind: .artists)
            case .playlists: LibraryCollectionView(kind: .playlists)
            case .favorites: FavoriteTracksView()
            case .genres: GenreListView()
            }
        }
    }
}

/// 同じ幅の計算をホームと一覧で共有し、ウインドウのリサイズ時にも列を揃える。
struct AlbumGridMetrics {
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

struct AlbumGridView: View {
    let title: String
    var albums: [MediaItem]?

    @Environment(AuthStore.self) private var auth
    @Environment(AlbumCatalog.self) private var catalog

    private var items: [MediaItem] { albums ?? catalog.items }

    var body: some View {
        GeometryReader { geometry in
            let metrics = AlbumGridMetrics(width: geometry.size.width)
            ScrollView {
                LazyVStack(spacing: 0) {
                    LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 24) {
                        ForEach(items) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                AlbumCard(item: album, size: metrics.size)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)

                    if albums == nil {
                        if let message = catalog.errorMessage {
                            LibraryLoadError(message: message) { await loadNext() }
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
    }

    private func loadNext() async {
        guard let client = auth.client else { return }
        await catalog.loadNext { try await client.fetchAlbums(startIndex: $0) }
    }
}

private struct GenreListView: View {
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
                            AlbumGridView(title: genre, albums: catalog.albums(in: genre))
                        } label: {
                            Text(genre)
                        }
                    }
                }
            } else if let message = catalog.errorMessage {
                LibraryLoadError(message: message) { await load() }
            } else {
                ProgressView("すべてのアルバムを確認中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("ジャンル")
        .task { await load() }
    }

    private func load() async {
        guard let client = auth.client else { return }
        await catalog.loadAll { try await client.fetchAlbums(startIndex: $0) }
    }
}

private struct LibraryCollectionView: View {
    enum Kind { case artists, playlists }
    let kind: Kind
    @Environment(LibraryStore.self) private var library
    @State private var isLoading = true

    private var items: [MediaItem] { kind == .artists ? library.artists : library.playlists }
    private var title: String { kind == .artists ? "アーティスト" : "プレイリスト" }

    var body: some View {
        List(items) { item in
            NavigationLink {
                if kind == .artists { ArtistDetailView(artist: item) } else { AlbumDetailView(album: item) }
            } label: {
                if kind == .artists {
                    ArtistRow(artist: item)
                } else {
                    HStack(spacing: 12) {
                        ArtworkView(item: item, size: 52, cornerRadius: 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName)
                            Text(item.albumSubtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .overlay {
            if isLoading, items.isEmpty {
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
        if kind == .artists { await library.loadArtists() } else { await library.loadPlaylists() }
        isLoading = false
    }
}

struct FavoriteTracksView: View {
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
                    TrackRow(track: track, showsArtwork: true, isPlaying: player.currentItem?.id == track.id)
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
                    LibraryLoadError(message: message) { await library.loadHome(force: true) }
                case .loaded: ContentUnavailableView("お気に入りの曲がありません", systemImage: "star")
                }
            }
        }
        .task { await library.loadHome() }
        .refreshable { await library.loadHome(force: true) }
    }
}

struct LibraryLoadError: View {
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
