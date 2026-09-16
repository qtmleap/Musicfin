import SwiftUI
import UIKit

/// アーティストのアルバム一覧。iPad の広い画面では作品種別と関連項目を横方向に展開する。
struct ArtistDetailView: View {
    let artist: MediaItem

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var albums: [MediaItem] = []
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true

    private var usesWideLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }
    /// 本文の左右余白。iPad は detail の 34.5 pt に揃える（仕様 6 章）。
    /// 幅が狭くて `compactBody` へ落ちても、detail の余白そのものは変わらない。
    private var horizontalMargin: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 34.5 : 20
    }

    private var singlesAndEPs: [MediaItem] {
        albums.filter(isSingleOrEP)
    }

    private var fullAlbums: [MediaItem] {
        albums.filter { !isSingleOrEP($0) }
    }

    private var artistPlaylists: [MediaItem] {
        library.playlists.filter { item in
            itemReferencesArtist(item)
                || item.displayName.localizedCaseInsensitiveContains(artist.displayName)
                || item.overview?.localizedCaseInsensitiveContains(artist.displayName) == true
        }
    }

    private var similarArtists: [MediaItem] {
        let genres = Set((artist.genres ?? []).map(normalizedMetadata))
        guard !genres.isEmpty else { return [] }
        return library.artists.filter { candidate in
            candidate.id != artist.id
                && !genres.isDisjoint(with: Set((candidate.genres ?? []).map(normalizedMetadata)))
        }
    }

    var body: some View {
        Group {
            if usesWideLayout {
                wideBody
            } else {
                compactBody
            }
        }
        .background(AppBackdrop())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { artistToolbar }
        .overlay(alignment: .topLeading) {
            if !isLoading {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("artist.detail.loaded")
            }
        }
        .task { await load() }
    }

    private var compactBody: some View {
        GeometryReader { geometry in
            let metrics = AlbumGridMetrics(
                width: geometry.size.width, horizontalMargin: horizontalMargin)
            ScrollView {
                VStack(spacing: 20) {
                    // 画像の下端から名前の見える上端まで 15 pt（Apple 実機の実測）。
                    // 文字の上に行送りの余白が 8 pt ほど入るので、間隔そのものは 7 pt で足りる。
                    VStack(spacing: 7) {
                        // 円・操作行・グリッドの 3 つが揃って 4 pt ずつ上にあったので、内側の間隔ではなく
                        // 先頭の上端だけで下げる。中身の縦の関係は Apple 実機と一致している。
                        ArtworkView(item: artist, size: 86, cornerRadius: 43)
                            .padding(.top, 12)

                        HStack(spacing: 6) {
                            Text(artist.displayName)
                                .font(.title.bold())
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 24)
                    }

                    TrackListActions(
                        play: { player.play(items: tracks) },
                        shuffle: { player.play(items: tracks, shuffled: true) },
                        height: 48,
                        listInsets: nil
                    )
                    .disabled(tracks.isEmpty)
                    // `AlbumGridMetrics` に渡した左右余白へ、操作行とグリッドを揃える。
                    .padding(.horizontal, horizontalMargin)

                    compactAlbums(metrics: metrics)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func compactAlbums(metrics: AlbumGridMetrics) -> some View {
        if isLoading {
            ProgressView().padding(.top, 40)
        } else if albums.isEmpty {
            ContentUnavailableView("アルバムがありません", systemImage: "square.stack")
                .padding(.top, 40)
        } else {
            LazyVGrid(
                columns: metrics.gridItems, alignment: .leading,
                spacing: AlbumGridMetrics.rowSpacing
            ) {
                ForEach(albums) { album in
                    albumLink(album, size: metrics.size)
                }
            }
            .padding(.horizontal, horizontalMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 操作行の下端からカードの上端まで 24 pt（Apple 実機の実測）。親の 20 pt に 4 pt 足す。
            .padding(.top, 4)
        }
    }

    private var wideBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .bottom, spacing: 30) {
                    ArtworkView(item: artist, size: 250, cornerRadius: 125)
                    VStack(alignment: .leading, spacing: 20) {
                        Text(artist.displayName)
                            .font(.system(size: 46, weight: .bold))
                            .lineLimit(2)
                        TrackListActions(
                            play: { player.play(items: tracks) },
                            shuffle: { player.play(items: tracks, shuffled: true) },
                            height: 48,
                            listInsets: nil
                        )
                        .frame(maxWidth: 440)
                        .disabled(tracks.isEmpty)
                    }
                    .padding(.bottom, 8)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                } else {
                    mediaSection(title: "Albums", items: fullAlbums)
                    mediaSection(
                        title: "Artist Playlists", items: artistPlaylists,
                        identifier: "artist.section.playlists")
                    mediaSection(
                        title: "Singles & EPs", items: singlesAndEPs,
                        identifier: "artist.section.singles-eps")
                    similarArtistsSection
                }
            }
            // detail の本文左端は sidebar の板から 34.5 pt（仕様 6 章）。一覧やアルバムと揃える。
            .padding(.horizontal, 34.5)
            .padding(.top, 20)
            // RootView の詳細用ミニプレイヤーに最後の行が隠れない高さを確保する。
            .padding(.bottom, 130)
        }
        .accessibilityIdentifier("artist.detail.viewport")
    }

    private func mediaSection(
        title: LocalizedStringKey, items: [MediaItem], identifier: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.bold())
                .accessibilityIdentifier(identifier ?? "")

            if items.isEmpty {
                Text("利用できる項目がありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 30)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(items) { item in
                            albumLink(item, size: 190)
                        }
                    }
                }
            }
        }
    }

    private var similarArtistsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Similar Artists")
                .font(.title2.bold())
                .accessibilityIdentifier("artist.section.similar-artists")

            if similarArtists.isEmpty {
                Text("利用できる項目がありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 30)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 22) {
                        ForEach(similarArtists) { candidate in
                            NavigationLink {
                                ArtistDetailView(artist: candidate)
                            } label: {
                                VStack(spacing: 9) {
                                    ArtworkView(item: candidate, size: 170, cornerRadius: 85)
                                    Text(candidate.displayName)
                                        .font(.footnote)
                                        .lineLimit(1)
                                }
                                .frame(width: 170)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("artist.similar.card")
                        }
                    }
                }
            }
        }
    }

    private func albumLink(_ album: MediaItem, size: CGFloat) -> some View {
        NavigationLink {
            AlbumDetailView(album: album)
        } label: {
            // 同じアーティストの一覧なので、サブタイトルは名前の繰り返しではなく年にする。
            AlbumCard(
                item: album, size: size,
                subtitle: album.productionYear.map(String.init) ?? "")
        }
        .buttonStyle(.plain)
        // 撮影テストがアルバムを持つアーティストを選べるよう、一覧と同じ識別子を付ける。
        .accessibilityIdentifier("album.card")
    }

    @ToolbarContentBuilder
    private var artistToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            ControlGroup {
                Button {
                    Task { await library.toggleFavorite(artist) }
                } label: {
                    // ツールバーの記号はアクセント色にしない（仕様 1.1 章）。tint を継がせない。
                    Image(systemName: artist.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(Color.primary)
                }
                .accessibilityLabel(artist.isFavorite ? "お気に入りから削除" : "お気に入りに追加")

                Menu {
                    Button {
                        Task { await library.toggleFavorite(artist) }
                    } label: {
                        Label(
                            artist.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                            systemImage: artist.isFavorite ? "star.slash" : "star"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.primary)
                }
                .accessibilityLabel("アーティストの操作")
            }
        }
    }

    private func isSingleOrEP(_ album: MediaItem) -> Bool {
        let name = normalizedMetadata(album.displayName)
        let hasReleaseSuffix =
            name.hasSuffix(" single") || name.hasSuffix("-single") || name.hasSuffix(" ep")
            || name.hasSuffix("-ep") || name.contains(" single ") || name.contains(" ep ")
        return hasReleaseSuffix || (album.childCount.map { $0 <= 3 } ?? false)
    }

    private func itemReferencesArtist(_ item: MediaItem) -> Bool {
        item.artistItems?.contains { $0.id == artist.id } == true
            || item.albumArtists?.contains { $0.id == artist.id } == true
            || item.artists?.contains {
                normalizedMetadata($0) == normalizedMetadata(artist.displayName)
            } == true
            || item.albumArtist.map(normalizedMetadata) == normalizedMetadata(artist.displayName)
    }

    private func normalizedMetadata(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        async let fetchedAlbums = library.albums(byArtist: artist)
        // iPad は compact 幅で生成されたあとに split view が展開し得るため、初期 size class では省かない。
        if UIDevice.current.userInterfaceIdiom == .pad {
            await library.loadPlaylists()
            await library.loadArtists()
        }
        albums = await fetchedAlbums
        // 専用の全曲APIを増やさず、表示に必要なアルバム取得結果から再生キューを組み立てる。
        tracks = await withTaskGroup(of: [MediaItem].self, returning: [MediaItem].self) { group in
            for album in albums {
                group.addTask { await library.tracks(for: album) }
            }
            var result: [MediaItem] = []
            for await albumTracks in group { result.append(contentsOf: albumTracks) }
            return result
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack {
        ArtistDetailView(artist: MediaItem(id: "preview", name: "Preview Artist", type: .musicArtist))
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
}
