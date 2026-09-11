import SwiftUI

/// ホーム。縦構成は `docs/ui-spec.md` 2 章のとおり（最近追加 / よく聴く / お気に入りの曲 / アルバムを探す）。
struct FableHomeView: View {
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
                        FableLoadError(message: message) { await library.loadHome(force: true) }
                    }
                    if let message = catalog.errorMessage {
                        FableLoadError(message: message) { await loadAlbums(force: true) }
                    }
                }
                .padding(.vertical, 16)
            }
            .overlay { emptyState }
            .refreshable { await load(force: true) }
        }
        .background(FableBackdrop())
        .navigationTitle("ホーム")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("設定", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) { FableSettingsView() }
        .task { await load() }
    }

    // MARK: - セクション

    private func albumCarousel(_ title: String, items: [MediaItem], size: CGFloat) -> some View {
        FableCarousel(title: title) {
            FableAlbumGridView(title: title, albums: items)
        } content: {
            ForEach(items) { album in
                NavigationLink {
                    FableAlbumDetailView(album: album)
                } label: {
                    FableAlbumCard(item: album, size: size)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 3 曲ずつの列をガラスのパネルに載せる。行だけを並べると背景のグラデーションに溶けて読みにくいため。
    private var favoriteCarousel: some View {
        FableCarousel(title: "お気に入りの曲") {
            FableFavoriteTracksView()
        } content: {
            ForEach(Array(stride(from: 0, to: favorites.count, by: 3)), id: \.self) { start in
                VStack(spacing: 0) {
                    ForEach(start..<min(start + 3, favorites.count), id: \.self) { index in
                        let track = favorites[index]
                        Button {
                            player.play(items: favorites, startingAt: index)
                        } label: {
                            FableTrackRow(
                                track: track, showsArtwork: true, isPlaying: player.currentItem?.id == track.id
                            )
                            .padding(.horizontal, 12)
                            .frame(height: 64)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 280, height: 192, alignment: .top)
                .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private func exploreAlbums(width: CGFloat) -> some View {
        let metrics = FableGridMetrics(width: width)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("アルバムを探す").font(.title2.bold())
                Spacer(minLength: 8)
                Button("すべて表示", action: showAlbums)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 24) {
                ForEach(catalog.items.prefix(6)) { album in
                    NavigationLink {
                        FableAlbumDetailView(album: album)
                    } label: {
                        FableAlbumCard(item: album, size: metrics.size)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 状態表示

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

    // MARK: - 読み込み

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
    NavigationStack {
        FableHomeView {}
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
    .environment(PlaybackSettings())
    .environment(AlbumCatalog())
}
