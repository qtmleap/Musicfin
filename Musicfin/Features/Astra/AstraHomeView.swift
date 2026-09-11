import SwiftUI

/// 作品の画像と余白で区切り、ログイン・設定と同じ装飾を抑えた階層にする。
struct AstraHomeView: View {
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
                        AstraLibraryLoadError(message: message) { await library.loadHome(force: true) }
                    }
                    if let message = catalog.errorMessage {
                        AstraLibraryLoadError(message: message) { await loadAlbums(force: true) }
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
        .sheet(isPresented: $showsSettings) { AstraSettingsView() }
        .task { await load() }
    }

    private func albumCarousel(_ title: String, items: [MediaItem], size: CGFloat) -> some View {
        AstraCarouselSection(
            title: title, destination: { AnyView(AstraAlbumGridView(title: title, albums: items)) },
            content: {
                ForEach(items) { album in
                    NavigationLink {
                        AstraAlbumDetailView(album: album)
                    } label: {
                        AstraAlbumCard(item: album, size: size)
                    }
                    .buttonStyle(.plain)
                }
            })
    }

    private var favoriteCarousel: some View {
        AstraCarouselSection(
            title: "お気に入りの曲", destination: { AnyView(AstraFavoriteTracksView()) },
            content: {
                ForEach(Array(stride(from: 0, to: favorites.count, by: 3)), id: \.self) { start in
                    VStack(spacing: 0) {
                        ForEach(start..<min(start + 3, favorites.count), id: \.self) { index in
                            let track = favorites[index]
                            Button {
                                player.play(items: favorites, startingAt: index)
                            } label: {
                                AstraTrackRow(
                                    track: track, showsArtwork: true, isPlaying: player.currentItem?.id == track.id,
                                    compact: true
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
        let metrics = AstraAlbumGridMetrics(width: width)
        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    exploreTitle
                    Spacer(minLength: 16)
                    exploreLink
                }
                VStack(alignment: .leading, spacing: 4) {
                    exploreTitle
                    exploreLink
                }
            }
            LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 24) {
                ForEach(catalog.items.prefix(6)) { album in
                    NavigationLink {
                        AstraAlbumDetailView(album: album)
                    } label: {
                        AstraAlbumCard(item: album, size: metrics.size)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var exploreTitle: some View {
        Text("アルバムを探す")
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var exploreLink: some View {
        Button("すべて表示", action: showAlbums)
            .font(.subheadline)
            .frame(minHeight: 44)
            .accessibilityLabel("アルバムを探す、すべて表示")
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

#Preview {
    NavigationStack { AstraHomeView {} }
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
        .environment(PlaybackSettings())
        .environment(AlbumCatalog())
}
