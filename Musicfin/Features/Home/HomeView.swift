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
            && library.recentlyPlayedTracks.isEmpty && favorites.isEmpty && catalog.items.isEmpty
    }
    /// iPad は detail の本文左端を sidebar の板から 34.5 pt 離す（仕様 6 章）。
    /// ここを 20 pt のままにすると、同じ detail の一覧画面より本文だけ左に出てしまう。
    private var horizontalMargin: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 34.5 : 20
    }

    /// Top Picks の 1 枚は裸のアートワークではなく、内余白 16 pt の板にアートワークと
    /// 3 行を収めたカード（Apple 実機の実測、仕様 2 章）。板の上下端がそのまま段の境界
    /// として見えるので、アートワークだけを並べると外枠の横線が 1 本足りなくなる。
    private static let topPickInset: CGFloat = 16
    private var topPickMetrics: (width: CGFloat, height: CGFloat, spacing: CGFloat, artwork: CGFloat) {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let width: CGFloat = pad ? 234 : 240.5
        return (width, pad ? 311.5 : 320.7, pad ? 20 : 12, width - Self.topPickInset * 2)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    if !library.recentlyAdded.isEmpty || !favorites.isEmpty {
                        topPicks
                    }
                    if !library.recentlyPlayedAlbums.isEmpty {
                        albumCarousel(
                            "Recently Played", items: library.recentlyPlayedAlbums,
                            size: 160)
                    }
                    if !library.recentlyPlayedTracks.isEmpty { trackCarousel(feed: .recentlyPlayedTracks) }
                    if !favorites.isEmpty { trackCarousel(feed: .favoriteTracks) }
                    if !catalog.items.isEmpty { exploreAlbums(width: geometry.size.width) }
                    if case .failed(let message) = library.homeState {
                        LoadErrorView(message: message) { await library.loadHome(force: true) }
                    }
                    if let message = catalog.errorMessage {
                        LoadErrorView(message: message) { await loadAlbums(force: true) }
                    }
                }
                .padding(.top, 25)
                .padding(.bottom, 16)
            }
            .overlay { emptyState }
            .refreshable { await load(force: true) }
        }
        .background(AppBackdrop())
        .tint(.pink)
        .tabNavigationTitle(Text("ホーム"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsAccount = true
                } label: {
                    AccountAvatar(name: accountName, size: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("アカウント")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $showsAccount) { AccountView() }
        .task { await load() }
        .prefetchArtwork(
            library.recentlyAdded + library.recentlyPlayedAlbums + catalog.items, size: 200
        )
        .prefetchArtwork(favorites, size: 48)
    }

    private var topPicks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Picks for You")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, horizontalMargin)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal) {
                // iPad は 1 枚だと段が画面幅の 4 割しか埋まらず、板の上下端が横線として
                // 立たない。実機と同じく複数枚を並べて画面の幅を越えさせる。
                LazyHStack(alignment: .top, spacing: topPickMetrics.spacing) {
                    ForEach(library.recentlyAdded) { recommendation in
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
                    LibraryFeedLoader(feed: .recentlyAdded).frame(width: topPickMetrics.width)
                }
                .padding(.horizontal, horizontalMargin)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func editorialAlbumCard(_ album: MediaItem) -> some View {
        topPickCard {
            ArtworkView(item: album, size: topPickMetrics.artwork, cornerRadius: 12)
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
    }

    private var favoritesCollectionCard: some View {
        topPickCard {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemFill))
                Image(systemName: "star.fill")
                    .font(.system(size: 88, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: topPickMetrics.artwork, height: topPickMetrics.artwork)
            Text("Made By You")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Text("Favorite Songs")
                .font(.headline)
                .padding(.top, 2)
            Text(
                favorites.isEmpty
                    ? String(localized: "Songs you favorite will appear here.")
                    : String(localized: "Your favorite songs in one collection.")
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 1)
        }
    }

    /// Home の地を灰色の板で分断せず、参照の角丸の輪郭だけを残してカードのまとまりを保つ。
    private func topPickCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(Self.topPickInset)
        .frame(width: topPickMetrics.width, height: topPickMetrics.height, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
        // 透明な余白からも詳細へ進めるよう、タップ範囲をカードの外形まで広げる。
        .contentShape(.rect)
    }

    private func albumCarousel(_ title: LocalizedStringResource, items: [MediaItem], size: CGFloat)
        -> some View
    {
        CarouselSection(
            title: title, destination: { AlbumGridView(title: String(localized: title), feed: .recentlyPlayedAlbums) },
            content: {
                ForEach(items) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(item: album, size: size)
                    }
                    .buttonStyle(.plain)
                }
                LibraryFeedLoader(feed: .recentlyPlayedAlbums).frame(width: size)
            })
    }

    private func trackCarousel(feed: LibraryFeed) -> some View {
        let favorites = feed == .favoriteTracks ? favorites : library.recentlyPlayedTracks
        let title: LocalizedStringResource = feed == .favoriteTracks ? "お気に入りの曲" : "最近再生した曲"
        return
            CarouselSection(
                title: title, destination: { FavoriteTracksView(feed: feed) },
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
                    LibraryFeedLoader(feed: feed).frame(width: 280)
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
            LazyVGrid(
                columns: metrics.gridItems, alignment: .leading, spacing: AlbumGridMetrics.rowSpacing
            ) {
                ForEach(catalog.items) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(item: album, size: metrics.size)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.album.\(album.id)")
                }
            }
            if !catalog.isComplete, catalog.errorMessage == nil, catalog.needsManualContinuation {
                Button("さらに読み込む") { Task { await loadNextAlbums() } }
            } else if !catalog.isComplete, catalog.errorMessage == nil {
                PaginationLoader(
                    revision: catalog.revision, isLoading: { catalog.isLoading }, load: { await loadNextAlbums() })
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

    private func loadNextAlbums() async {
        guard let client = auth.client else { return }
        await catalog.loadNext { try await client.fetchAlbums(startIndex: $0) }
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
