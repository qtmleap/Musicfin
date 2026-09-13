import SwiftUI

/// アーティストのアルバム一覧。円形のアートワークを見出しにして、下にアルバムをグリッドで並べる。
struct ArtistDetailView: View {
    let artist: MediaItem

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var albums: [MediaItem] = []
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geometry in
            let metrics = AlbumGridMetrics(width: geometry.size.width)
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
                        shuffle: {
                            if !player.isShuffled { player.toggleShuffle() }
                            player.play(items: tracks)
                        },
                        height: 48,
                        listInsets: nil
                    )
                    .disabled(tracks.isEmpty)
                    // `AlbumGridMetrics` が前提にしている左右 20 pt に、操作行とグリッドを揃える。
                    .padding(.horizontal, 20)

                    if isLoading {
                        ProgressView().padding(.top, 40)
                    } else if albums.isEmpty {
                        ContentUnavailableView("アルバムがありません", systemImage: "square.stack")
                            .padding(.top, 40)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            LazyVGrid(
                                columns: metrics.gridItems, alignment: .leading,
                                spacing: AlbumGridMetrics.rowSpacing
                            ) {
                                ForEach(albums) { album in
                                    NavigationLink {
                                        AlbumDetailView(album: album)
                                    } label: {
                                        // 同じアーティストの一覧なので、サブタイトルは名前の繰り返しではなく年にする。
                                        AlbumCard(
                                            item: album, size: metrics.size,
                                            subtitle: album.productionYear.map(String.init) ?? "")
                                    }
                                    .buttonStyle(.plain)
                                    // 撮影テストがアルバムを持つアーティストを選べるよう、一覧と同じ識別子を付ける。
                                    .accessibilityIdentifier("album.card")
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 操作行の下端からカードの上端まで 24 pt（Apple 実機の実測）。親の 20 pt に 4 pt 足す。
                        // 親の `spacing` を 24 にしないのは、そこが名前ブロック→操作行の 20 pt も同時に
                        // 決めていて、そちらは実測と合っているため。読み込み中と空の分岐も巻き添えになる。
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
        }
        .background(AppBackdrop())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .task {
            albums = await library.albums(byArtist: artist)
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
}

#Preview {
    NavigationStack {
        ArtistDetailView(artist: MediaItem(id: "preview", name: "Preview Artist", type: .musicArtist))
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
}
