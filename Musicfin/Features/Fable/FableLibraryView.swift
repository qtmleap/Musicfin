import SwiftUI

enum FableLibraryRoute: Hashable {
    case albums, artists, playlists, favorites, genres
}

/// ライブラリの入口。iPod のメニューのように種類を縦に並べ、それぞれの一覧へ入れ子で進む。
struct FableLibraryView: View {
    var body: some View {
        List {
            Section {
                menuRow("アルバム", systemImage: "square.stack", route: .albums)
                menuRow("アーティスト", systemImage: "music.mic", route: .artists)
                menuRow("プレイリスト", systemImage: "music.note.list", route: .playlists)
                menuRow("お気に入りの曲", systemImage: "heart", route: .favorites)
                menuRow("ジャンル", systemImage: "guitars", route: .genres)
            }
        }
        .scrollContentBackground(.hidden)
        .background(FableBackdrop())
        .navigationTitle("ライブラリ")
        .navigationDestination(for: FableLibraryRoute.self) { route in
            switch route {
            case .albums: FableAlbumGridView(title: "アルバム")
            case .artists: FableCollectionView(kind: .artists)
            case .playlists: FableCollectionView(kind: .playlists)
            case .favorites: FableFavoriteTracksView()
            case .genres: FableGenreListView()
            }
        }
    }

    private func menuRow(_ title: String, systemImage: String, route: FableLibraryRoute) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                FableMenuIcon(systemImage: systemImage)
                Text(title)
                    .font(.body.weight(.medium))
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - アルバム一覧

/// アルバムのグリッド。`albums` を渡せばその一覧を、渡さなければカタログ全体を無限スクロールで出す。
struct FableAlbumGridView: View {
    let title: String
    var albums: [MediaItem]?

    @Environment(AuthStore.self) private var auth
    @Environment(AlbumCatalog.self) private var catalog

    private var items: [MediaItem] { albums ?? catalog.items }

    var body: some View {
        GeometryReader { geometry in
            let metrics = FableGridMetrics(width: geometry.size.width)
            ScrollView {
                LazyVStack(spacing: 0) {
                    LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 24) {
                        ForEach(items) { album in
                            NavigationLink {
                                FableAlbumDetailView(album: album)
                            } label: {
                                FableAlbumCard(item: album, size: metrics.size)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)

                    if albums == nil {
                        if let message = catalog.errorMessage {
                            FableLoadError(message: message) { await loadNext() }
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
        .background(FableBackdrop())
        .navigationTitle(title)
    }

    private func loadNext() async {
        guard let client = auth.client else { return }
        await catalog.loadNext { try await client.fetchAlbums(startIndex: $0) }
    }
}

// MARK: - ジャンル

/// ジャンルは全アルバムを読み切ってから集約する（途中の分類を全件として見せない）。
struct FableGenreListView: View {
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
                            FableAlbumGridView(title: genre, albums: catalog.albums(in: genre))
                        } label: {
                            HStack(spacing: 14) {
                                FableMenuIcon(systemImage: "guitars")
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
                FableLoadError(message: message) { await load() }
            } else {
                ProgressView("すべてのアルバムを確認中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FableBackdrop())
        .navigationTitle("ジャンル")
        .task { await load() }
    }

    private func load() async {
        guard let client = auth.client else { return }
        await catalog.loadAll { try await client.fetchAlbums(startIndex: $0) }
    }
}

// MARK: - アーティスト / プレイリスト

struct FableCollectionView: View {
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
                    FableArtistDetailView(artist: item)
                } else {
                    FableAlbumDetailView(album: item)
                }
            } label: {
                if kind == .artists {
                    FableArtistRow(artist: item)
                } else {
                    FableContainerRow(item: item)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FableBackdrop())
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

struct FableFavoriteTracksView: View {
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
                    FableTrackRow(track: track, showsArtwork: true, isPlaying: player.currentItem?.id == track.id)
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
        .background(FableBackdrop())
        .navigationTitle("お気に入りの曲")
        .overlay {
            if tracks.isEmpty {
                switch library.homeState {
                case .idle, .loading: ProgressView()
                case .failed(let message):
                    FableLoadError(message: message) { await library.loadHome(force: true) }
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
        FableLibraryView()
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
    .environment(AlbumCatalog())
}
