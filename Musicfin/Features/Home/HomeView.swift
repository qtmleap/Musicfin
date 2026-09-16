import SwiftUI

/// ホーム。最近追加・よく聴く・お気に入り・アルバム一覧を縦に並べる（`docs/ui-spec.md` 2 章）。
struct HomeView: View {
    let showAlbums: () -> Void
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @Environment(AlbumCatalog.self) private var catalog
    @State private var showsAccount = false

    private var favorites: [MediaItem] { library.favoriteTracks.filter(\.isFavorite) }
    private var accountName: String? {
        if case .signedIn(let user) = auth.state, !user.isEmpty { return user }
        return nil
    }
    private var isEmpty: Bool {
        library.recentlyAdded.isEmpty && library.recentlyPlayedAlbums.isEmpty
            && favorites.isEmpty && catalog.items.isEmpty
    }
    /// iPad は detail の本文左端を sidebar の板から 34.5 pt 離す（仕様 6 章）。
    /// ここを 20 pt のままにすると、同じ detail の一覧画面より本文だけ左に出てしまう。
    private var horizontalMargin: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 34.5 : 20
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                // 大見出しの直後だけ、Apple は区分と区分の間（32 pt）より狭い 30 pt で次へ移る。
                // 見出しの行を `LazyVStack` の外へ出し、そこだけ別の間隔を与えている。
                VStack(alignment: .leading, spacing: 25) {
                    HStack {
                        Text("ホーム")
                            .font(.largeTitle.bold())
                        Spacer()
                        Button {
                            showsAccount = true
                        } label: {
                            AccountAvatar(name: accountName, size: 44)
                        }
                        .accessibilityLabel("アカウント")
                    }
                    .padding(.horizontal, horizontalMargin)

                    LazyVStack(alignment: .leading, spacing: 32) {
                        if !library.recentlyAdded.isEmpty || !favorites.isEmpty {
                            topPicks
                        }
                        if !library.recentlyPlayedAlbums.isEmpty {
                            albumCarousel(
                                "Recently Played", items: library.recentlyPlayedAlbums, size: 160)
                        }
                        if !favorites.isEmpty { favoriteCarousel }
                        if !catalog.items.isEmpty { exploreAlbums(width: geometry.size.width) }
                        if case .failed(let message) = library.homeState {
                            LoadErrorView(message: message) { await library.loadHome(force: true) }
                        }
                        if let message = catalog.errorMessage {
                            LoadErrorView(message: message) { await loadAlbums(force: true) }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .overlay { emptyState }
            .refreshable { await load(force: true) }
        }
        .background(AppBackdrop())
        .tint(.pink)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsAccount) { AccountView() }
        .task { await load() }
    }

    private var topPicks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Picks for You")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, horizontalMargin)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    if let recommendation = library.recentlyAdded.first {
                        NavigationLink {
                            AlbumDetailView(album: recommendation)
                        } label: {
                            editorialAlbumCard(recommendation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.top-pick.\(recommendation.id)")
                    }

                    NavigationLink {
                        FavoriteTracksView()
                    } label: {
                        favoritesCollectionCard
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.top-pick.favorites")
                }
                .padding(.horizontal, horizontalMargin)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func editorialAlbumCard(_ album: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(item: album, size: 241, cornerRadius: 12)
            Text("Trending with \(album.displayArtist ?? album.albumArtist ?? album.displayName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 8)
            Text(album.displayName)
                .font(.headline)
                .lineLimit(1)
                .padding(.top, 2)
            if let artist = album.displayArtist ?? album.albumArtist {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 1)
            }
        }
        .frame(width: 241, height: 321, alignment: .topLeading)
    }

    private var favoritesCollectionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                Image(systemName: "star.fill")
                    .font(.system(size: 88, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 241, height: 241)
            Text("Made By You")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Text("Favorite Songs")
                .font(.headline)
                .padding(.top, 2)
            Text(favorites.isEmpty ? "Songs you favorite will appear here." : "Your favorite songs in one collection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(width: 241, height: 321, alignment: .topLeading)
    }

    private func albumCarousel(_ title: LocalizedStringResource, items: [MediaItem], size: CGFloat) -> some View {
        CarouselSection(
            title: title, destination: { AlbumGridView(title: String(localized: title), albums: items) },
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
            title: "お気に入りの曲", destination: { FavoriteTracksView() },
            content: {
                ForEach(Array(stride(from: 0, to: favorites.count, by: 3)), id: \.self) { start in
                    VStack(spacing: 0) {
                        ForEach(start..<min(start + 3, favorites.count), id: \.self) { index in
                            let track = favorites[index]
                            // 操作をスワイプに隠さず、行末の「…」から出す（仕様 1.1 章）。
                            HStack(spacing: 0) {
                                Button {
                                    player.play(items: favorites, startingAt: index)
                                } label: {
                                    // 3 段組の行は仕様 2 章どおり画像 44 pt のまま（一覧の 48 pt とは別）。
                                    TrackRow(
                                        track: track, showsArtwork: true,
                                        isCurrent: player.currentItem?.id == track.id
                                    )
                                    // 文字拡大時は行を伸ばし、3 段の固定高で文字を押し潰さない。
                                    .frame(minHeight: 64)
                                }
                                .buttonStyle(.plain)

                                RowMenu {
                                    Button {
                                        player.playNext([track])
                                    } label: {
                                        Label(
                                            "次に再生",
                                            systemImage: "text.line.first.and.arrowtriangle.forward"
                                        )
                                    }
                                    Button {
                                        Task { await library.toggleFavorite(track) }
                                    } label: {
                                        Label(
                                            track.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                                            systemImage: track.isFavorite ? "heart.slash" : "heart"
                                        )
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 280, alignment: .top)
                }
            })
    }

    private func exploreAlbums(width: CGFloat) -> some View {
        let metrics = AlbumGridMetrics(width: width, horizontalMargin: horizontalMargin)
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
            LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: AlbumGridMetrics.rowSpacing) {
                ForEach(catalog.items.prefix(10)) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(item: album, size: metrics.size)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, horizontalMargin)
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
    NavigationStack { HomeView {} }
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
        .environment(PlaybackSettings())
        .environment(AlbumCatalog())
}
