import SwiftUI

enum LibraryRoute: Hashable {
    case albums, artists, playlists, favorites, genres
}

/// ライブラリの入口。iPod のメニューのように種類を縦に並べ、それぞれの一覧へ入れ子で進む。
struct LibraryView: View {
    var body: some View {
        List {
            NavigationLink(value: LibraryRoute.albums) { Label("アルバム", systemImage: "square.stack") }
            NavigationLink(value: LibraryRoute.artists) { Label("アーティスト", systemImage: "music.mic") }
            NavigationLink(value: LibraryRoute.playlists) { Label("プレイリスト", systemImage: "music.note.list") }
            NavigationLink(value: LibraryRoute.favorites) { Label("お気に入りの曲", systemImage: "star") }
            NavigationLink(value: LibraryRoute.genres) { Label("ジャンル", systemImage: "guitars") }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppBackdrop())
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

// MARK: - アルバム一覧

/// アルバムのグリッド。`albums` を渡せばその一覧を、渡さなければカタログ全体を無限スクロールで出す。
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
                            LoadErrorView(message: message) { await loadNext() }
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
        .background(AppBackdrop())
        .navigationTitle(title)
    }

    private func loadNext() async {
        guard let client = auth.client else { return }
        await catalog.loadNext { try await client.fetchAlbums(startIndex: $0) }
    }
}

// MARK: - ジャンル

/// ジャンルは全アルバムを読み切ってから集約する（途中の分類を全件として見せない）。
struct GenreListView: View {
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
                            HStack(spacing: 14) {
                                MenuIcon(systemImage: "guitars")
                                Text(genre)
                                Spacer()
                                Text("\(catalog.albums(in: genre).count)")
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            } else if let message = catalog.errorMessage {
                LoadErrorView(message: message) { await load() }
            } else {
                ProgressView("すべてのアルバムを確認中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppBackdrop())
        .navigationTitle("ジャンル")
        .task { await load() }
    }

    private func load() async {
        guard let client = auth.client else { return }
        await catalog.loadAll { try await client.fetchAlbums(startIndex: $0) }
    }
}

// MARK: - アーティスト / プレイリスト

struct LibraryCollectionView: View {
    enum Kind { case artists, playlists }
    let kind: Kind

    @Environment(LibraryStore.self) private var library
    @State private var isLoading = true

    private var items: [MediaItem] { kind == .artists ? library.artists : library.playlists }
    private var title: String { kind == .artists ? "アーティスト" : "プレイリスト" }

    var body: some View {
        List(items) { item in
            NavigationLink {
                if kind == .artists {
                    ArtistDetailView(artist: item)
                } else {
                    AlbumDetailView(album: item)
                }
            } label: {
                if kind == .artists {
                    ArtistRow(artist: item)
                } else {
                    ContainerRow(item: item)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackdrop())
        .navigationTitle(title)
        .overlay {
            if isLoading, items.isEmpty {
                ProgressView()
            } else if items.isEmpty {
                ContentUnavailableView(
                    "\(title)がありません", systemImage: kind == .artists ? "music.mic" : "music.note.list")
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

// MARK: - お気に入りの曲

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
                        Label("お気に入りから削除", systemImage: "heart.slash")
                    }
                    .tint(.pink)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppBackdrop())
        .navigationTitle("お気に入りの曲")
        .overlay {
            if tracks.isEmpty {
                switch library.homeState {
                case .idle, .loading: ProgressView()
                case .failed(let message):
                    LoadErrorView(message: message) { await library.loadHome(force: true) }
                case .loaded: ContentUnavailableView("お気に入りの曲がありません", systemImage: "heart")
                }
            }
        }
        .task { await library.loadHome() }
        .refreshable { await library.loadHome(force: true) }
    }
}

#Preview {
    NavigationStack {
        LibraryView()
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
    .environment(AlbumCatalog())
}
