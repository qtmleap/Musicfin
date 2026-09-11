import SwiftUI

struct HomeView: View {
    let showAlbums: () -> Void
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @Environment(AlbumCatalog.self) private var catalog
    @State private var showsSettings = false

    private var favorites: [MediaItem] { library.favoriteTracks.filter(\.isFavorite) }
    private var isEmpty: Bool {
        library.recentlyAdded.isEmpty && library.frequentlyPlayed.isEmpty
            && favorites.isEmpty && catalog.items.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    if !library.recentlyAdded.isEmpty {
                        albumCarousel("最近追加したアルバム", items: library.recentlyAdded, size: 180)
                    }
                    if !library.frequentlyPlayed.isEmpty {
                        albumCarousel("よく聴くアルバム", items: library.frequentlyPlayed, size: 160)
                    }
                    if !favorites.isEmpty { favoriteCarousel }
                    if !catalog.items.isEmpty { exploreAlbums(width: geometry.size.width) }
                    if case .failed(let message) = library.homeState {
                        LibraryLoadError(message: message) { await library.loadHome(force: true) }
                    }
                    if let message = catalog.errorMessage {
                        LibraryLoadError(message: message) { await loadAlbums(force: true) }
                    }
                }
                .padding(.vertical, 16)
            }
            .overlay { emptyState }
            .refreshable { await load(force: true) }
        }
        .navigationTitle("ホーム")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("設定", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) { DesignVariant.current.settingsView }
        .task { await load() }
    }

    private func albumCarousel(_ title: String, items: [MediaItem], size: CGFloat) -> some View {
        CarouselSection(
            title: title, destination: { AnyView(AlbumGridView(title: title, albums: items)) },
            content: {
                ForEach(items) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(item: album, size: size)
                    }
                    .buttonStyle(.plain)
                }
            })
    }

    private var favoriteCarousel: some View {
        CarouselSection(
            title: "お気に入りの曲", destination: { AnyView(FavoriteTracksView()) },
            content: {
                ForEach(Array(stride(from: 0, to: favorites.count, by: 3)), id: \.self) { start in
                    VStack(spacing: 0) {
                        ForEach(start..<min(start + 3, favorites.count), id: \.self) { index in
                            let track = favorites[index]
                            Button {
                                player.play(items: favorites, startingAt: index)
                            } label: {
                                TrackRow(
                                    track: track, showsArtwork: true, isPlaying: player.currentItem?.id == track.id
                                )
                                .frame(height: 64)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 280, height: 192, alignment: .top)
                }
            })
    }

    private func exploreAlbums(width: CGFloat) -> some View {
        let metrics = AlbumGridMetrics(width: width)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("アルバムを探す").font(.title2.bold())
                Spacer(minLength: 8)
                Button("すべて表示", action: showAlbums).font(.subheadline)
                    .frame(minHeight: 44)
            }
            LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 24) {
                ForEach(catalog.items.prefix(6)) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(item: album, size: metrics.size)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isEmpty {
            if library.homeState == .idle || library.homeState == .loading
                || catalog.isLoading || (catalog.errorMessage == nil && !catalog.isComplete)
            {
                ProgressView()
            } else if library.homeState == .loaded, catalog.isComplete {
                ContentUnavailableView(
                    "音楽がまだありません",
                    systemImage: "music.note",
                    description: Text("Jellyfin サーバーに音楽を追加すると、ここに表示されます。")
                )
            }
        }
    }

    private func load(force: Bool = false) async {
        async let home: Void = library.loadHome(force: force)
        async let albums: Void = loadAlbums(force: force)
        _ = await (home, albums)
    }

    private func loadAlbums(force: Bool = false) async {
        guard let client = auth.client else { return }
        if force {
            await catalog.refresh { try await client.fetchAlbums(startIndex: $0) }
        } else if catalog.items.isEmpty || catalog.errorMessage != nil {
            await catalog.loadNext { try await client.fetchAlbums(startIndex: $0) }
        }
    }
}
