import SwiftUI
import UIKit

/// アルバム／プレイリストの詳細。大きなアートワークと収録曲リスト。
/// 画像・題名・再生操作・メニューの実行処理は共用し、ヘッダーの内訳と曲行だけを種別で分ける（仕様 8 章）。
struct AlbumDetailView: View {
    let album: MediaItem

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true
    /// 罫線の左端は `TrackRow` の番号列と同じ基準で拡大させ、文字拡大時も曲名の左端に揃える。
    @ScaledMetric(relativeTo: .body) private var numberWidth: CGFloat = TrackRow.numberColumnWidth
    /// 再生カプセルの基準寸法。通常サイズでは仕様 7 章の 160×48 pt になる。
    @ScaledMetric(relativeTo: .headline) private var playWidth: CGFloat = 160
    @ScaledMetric(relativeTo: .headline) private var playHeight: CGFloat = 48
    /// プレイリストの曲行の画像。一覧（曲・お気に入り）と同じ 48 pt で、曲名の左端が 80 pt になる。
    /// 罫線の位置は `alignmentGuide` の Sendable なクロージャからも引くので隔離を外す。
    nonisolated private static let playlistArtworkSize: CGFloat = 48
    /// 再生操作行の円と、ボタン同士の間隔（仕様 7 章）。2 行に分かれても同じ値を使う。
    private static let circleSize: CGFloat = 48
    private static let buttonSpacing: CGFloat = 14
    /// 円の中の記号の寸法。**標準文字サイズのときの本文**と同じ大きさに固定する。
    /// 円を 48 pt で止めた以上、中の記号も止めるのが対であって、地だけ止めて記号を文字サイズへ
    /// 追従させると記号が円からはみ出し、地の外側に描かれる（仕様 7.1 章）。
    /// 48 pt の円は標準文字サイズを基準に決めた寸法なので、記号の基準も同じところから引く。
    /// 数値を直に書かないのは、本文の寸法が変わったときに円と記号で基準がずれないようにするため。
    private static let symbolSize = UIFont.preferredFont(
        forTextStyle: .body,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize

    /// プレイリストは曲ごとに作品も番号も違うため、番号・ディスク・作品情報を出さない（仕様 8 章）。
    private var isPlaylist: Bool { album.type == .playlist }

    var body: some View {
        // 背景・文字・罫線・3 ボタンの色はすべてアートワークから決まる（仕様 1.2 章）。
        // アルバムとプレイリストは同じ帯（明るい側）なので、種別で分けない。
        ArtworkBackdrop(item: album, band: .detail, artworkSize: 257) { palette in
            list(palette: palette)
        }
    }

    private func list(palette: ArtworkPalette) -> some View {
        List {
            header(palette: palette)
                .listRowInsets(EdgeInsets())
                // 収録曲の始まりを示す区切り線を 1 本だけ残す（Apple 実機に合わせる）。
                .listRowSeparator(.hidden, edges: .top)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 20 }
                // 罫線の右端は既定で 16 pt どまりなので、左と同じ 20 pt へ寄せる。
                .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] - 20 }
                .listRowBackground(Color.clear)
                // 収録曲の上の 1 本はこのヘッダー行が引くので、色もここで渡す。
                .listRowSeparatorTint(palette.separator)
                .id(palette.separator)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                trackList(separator: palette.separator)
            }
        }
        .listStyle(.plain)
        // 行の地を透明にしないと `List` の黒が残って背景が見えない（仕様 1.2 章）。
        .scrollContentBackground(.hidden)
        // 文字と記号は前景色に従わせる。`TrackRow` などの `.primary` / `.secondary` はここから派生する。
        .foregroundStyle(palette.foreground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent(palette: palette) }
        .task { await load() }
    }

    // MARK: - ヘッダー

    private func header(palette: ArtworkPalette) -> some View {
        VStack(spacing: 14) {
            // 画像下端から題名の見えるグリフ上端までが Apple 実機の 27 pt。
            // 指定 27 pt では実測 31.3 pt になり、行送りの余白 4.3 pt だけ広い分を引く。
            ArtworkView(item: album, size: 257, cornerRadius: 8)
                .padding(.bottom, 9)

            VStack(spacing: 4) {
                Text(album.displayName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    // 撮影テストが詳細へ着いたことを、一覧にも在る再生ボタンではなくここで判定する。
                    .accessibilityIdentifier(isPlaylist ? "playlist.detail" : "album.detail")

                // プレイリストの所有者を表すフィールドがモデルに無いので、作品側の
                // アーティストで代用せずに行ごと省く。ジャンル・年・曲数の行も Apple 参照に無い（仕様 8 章）。
                if !isPlaylist {
                    if let artist = album.albumArtist ?? album.displayArtist {
                        // アーティスト名はアクセント色にしない（仕様 1.1 章）。曲名と同じ前景色の 20 pt。
                        Text(artist)
                            .font(.title3)
                            .foregroundStyle(palette.foreground)
                    }

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.foreground)
                            .textCase(.uppercase)
                    }
                }
            }
            .padding(.horizontal, isPlaylist ? 20 : 24)

            playbackButtons(palette: palette)
        }
        .frame(maxWidth: .infinity)
        // ナビゲーション操作面の可視下端から画像上端までを 24 pt にする（仕様 7 章・8 章）。
        // 行の余白を `listRowInsets(EdgeInsets())` で殺してあるので、ここが唯一の調整点。
        // アルバムもプレイリストも同じヘッダーを通るため、分岐させずに両方が揃う。
        .padding(.top, 14)
        // 再生ボタン下端から最初の区切り線まで 24 pt（Apple 実機の実測）。
        .padding(.bottom, 24)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let genre = album.genres?.first { parts.append(genre) }
        if let year = album.productionYear { parts.append("\(year)") }
        if !tracks.isEmpty { parts.append(String(localized: "\(tracks.count) 曲")) }
        return parts.joined(separator: " · ")
    }

    /// 収まらないときはカプセルを上、円 2 つを下に分ける（仕様 7.1 章）。文字を切るより行を増やす。
    /// Apple 実機の文字拡大時の画像が無いので、この形は実測ではなく仕様 7.1 章からの決定。
    /// 判定は `ViewThatFits` に任せる。合計幅を自分で足すと、円やカプセルの寸法を変えたとき
    /// 判定側だけ古い値のまま残って黙ってずれる。文字サイズの段階で切り替えないのは、
    /// 訳語が長いだけで収まらない場合も同じ判定で拾うため。
    private func playbackButtons(palette: ArtworkPalette) -> some View {
        ViewThatFits(in: .horizontal) {
            // 48 + 14 + 160 + 14 + 48 = 284 pt。残り幅いっぱいには伸ばさず、親の中央に置く（仕様 7 章）。
            HStack(spacing: Self.buttonSpacing) {
                shuffleButton(palette: palette)
                playButton(fillsWidth: false, palette: palette)
                downloadButton(palette: palette)
            }

            VStack(spacing: Self.buttonSpacing) {
                // 上の行のカプセルだけは左右 16 pt の内側いっぱいまで使ってよい（仕様 7.1 章）。
                playButton(fillsWidth: true, palette: palette)
                // 円は 48 pt のまま。記号だけのボタンは文字量が増えないので拡大する理由がない（仕様 7.1 章）。
                HStack(spacing: Self.buttonSpacing) {
                    shuffleButton(palette: palette)
                    downloadButton(palette: palette)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
        .frame(maxWidth: .infinity)
        // 284 pt の行が収まらない幅でも左右 16 pt は空ける（仕様 7 章）。
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func shuffleButton(palette: ArtworkPalette) -> some View {
        Button {
            if !player.isShuffled { player.toggleShuffle() }
            player.play(items: tracks)
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: Self.symbolSize))
                .foregroundStyle(palette.foreground)
                .frame(width: Self.circleSize, height: Self.circleSize)
                .background(palette.circleFill, in: .circle)
        }
        // 押せるボタンなのに無効用の様式を当てるのは、**曲が 0 件のとき左右の円が食い違う**ため。
        // `.disabled(tracks.isEmpty)` は 3 ボタンをまとめて無効にするが、右の円はこの様式で
        // 減光されないので、左だけが薄くなって「左右の円の地は同じ色」（仕様 7 章）が壊れる。
        // 代償として `.plain` 由来の押下時の反応を失う。承知のうえで左右をそろえる側を採る。
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityLabel("シャッフル")
    }

    /// `fillsWidth` は 2 行に分けたときの上の行。1 行に収まる間は 160 pt の基準を保つ。
    /// 2 行に分けたら最小幅は外す。160 pt は通常文字サイズの基準（仕様 7 章）であって確保すべき下限ではなく、
    /// 拡大した `playWidth` を下限のまま残すと、行を分けても左右 16 pt の外へはみ出す。
    private func playButton(fillsWidth: Bool, palette: ArtworkPalette) -> some View {
        Button {
            player.play(items: tracks)
        } label: {
            // `Label` を 160 pt の枠に置くと記号と文字が離れるので、実機どおり 6 pt で並べ直す。
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text("再生")
            }
            .font(.headline)
            .foregroundStyle(palette.background)
            // 160×48 pt は通常サイズの基準（仕様 7 章）。文字拡大や長い訳語では切らずに広げる。
            .padding(.horizontal, 20)
            .frame(
                minWidth: fillsWidth ? nil : playWidth,
                maxWidth: fillsWidth ? .infinity : nil,
                minHeight: playHeight
            )
            // 地が前景色・文字が背景色の反転（仕様 7 章の表）。背景が明るければ黒地に明るい文字になる。
            .background(palette.foreground, in: .capsule)
        }
    }

    private func downloadButton(palette: ArtworkPalette) -> some View {
        Button {
        } label: {
            Image(systemName: "arrow.down")
                // 字形が細いので今は溢れないが、症状の有無ではなく円との対で決める（仕様 7.1 章）。
                // 片方だけ固定すると、同じ円に入る 2 つの記号が文字サイズで食い違う。
                .font(.system(size: Self.symbolSize))
                // 記号を薄くするのは Musicfin にダウンロードが無いことを形で示す決め。
                // Apple 実機は左の円と同じ濃さなので、実機に合わせた値ではない（仕様 7 章）。
                .foregroundStyle(palette.disabledForeground)
                .frame(width: Self.circleSize, height: Self.circleSize)
                .background(palette.circleFill, in: .circle)
        }
        // 押せないことと読み上げの「淡色表示」は `.disabled` に任せ、描画の減光だけ外す。
        .buttonStyle(UndimmedButtonStyle())
        .disabled(true)
        .accessibilityLabel("ダウンロード（未対応）")
    }

    // MARK: - 収録曲

    /// 罫線の色を `List` ではなく行ごとに渡すのは、`listRowSeparatorTint` が行の修飾子で、
    /// `List` 全体に掛けても無視されるため。黒を渡して 1 階調も動かないことを撮って確かめた。
    @ViewBuilder
    private func trackList(separator: Color) -> some View {
        if isPlaylist {
            // 取得した順がプレイリストの並び順そのもの。ディスク番号で組み替えると
            // 再生は元の順のまま走るので、表示順と再生順が食い違う（仕様 8 章）。
            ForEach(tracks) { trackRow($0, separator: separator).id(RowKey($0.id, separator)) }
        } else {
            let grouped = Dictionary(grouping: tracks) { $0.parentIndexNumber ?? 1 }
            let discs = grouped.keys.sorted()

            ForEach(discs, id: \.self) { disc in
                Section {
                    ForEach(grouped[disc] ?? []) {
                        trackRow($0, separator: separator).id(RowKey($0.id, separator))
                    }
                } header: {
                    // ディスクが 1 枚だけならヘッダーは出さない。
                    if discs.count > 1 {
                        Text("ディスク \(disc)")
                            // 節の見出しは `plain` でも地を持つので、ここも透かさないと
                            // 貼り付いた見出しの帯だけ背景が切れて見える（仕様 1.2 章）。
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
    }

    private func trackRow(_ track: MediaItem, separator: Color) -> some View {
        HStack(spacing: 0) {
            Button {
                if let index = tracks.firstIndex(where: { $0.id == track.id }) {
                    player.play(items: tracks, startingAt: index)
                }
            } label: {
                // プレイリストの番号は収録アルバム内の位置なので出さず、代わりに画像と
                // 曲ごとのアーティストで一覧と同じ見分け方にする（仕様 8 章）。
                TrackRow(
                    track: track,
                    showsArtwork: isPlaylist,
                    artworkSize: Self.playlistArtworkSize,
                    isCurrent: player.currentItem?.id == track.id,
                    isPlaying: player.isPlaying
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(isPlaylist ? "playlist.track" : "album.track")

            // 再生ボタンの外へ出し、「…」だけを押したときに曲を再生しない。
            RowMenu {
                Button {
                    player.playNext([track])
                } label: {
                    Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    player.appendToQueue([track])
                } label: {
                    Label("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward")
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
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(separator)
        // 行送り 52 pt。区切り線から曲名の中心までが Apple 実機と同じ 26 pt になる。
        // プレイリストは画像 48 pt なので同じ上下 4 pt で 56 pt になる。
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        // 区切り線は番号や画像の列に食い込ませず、曲名の左端から引く。
        .alignmentGuide(.listRowSeparatorLeading) { [numberWidth, isPlaylist] _ in
            isPlaylist
                ? Self.playlistArtworkSize + TrackRow.artworkTitleSpacing
                : numberWidth + TrackRow.numberTitleSpacing
        }
        // 右端も既定の 16 pt ではなく、行の右端（左右 20 pt）に揃える。
        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        .swipeActions(edge: .leading) {
            Button {
                player.playNext([track])
            } label: {
                Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button {
                Task { await library.toggleFavorite(track) }
            } label: {
                Label("お気に入り", systemImage: track.isFavorite ? "heart.slash" : "heart")
            }
            .tint(.pink)
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(palette: ArtworkPalette) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    player.appendToQueue(tracks)
                } label: {
                    Label("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                Button {
                    player.playNext(tracks)
                } label: {
                    Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { await library.toggleFavorite(album) }
                } label: {
                    Label(
                        album.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                        systemImage: album.isFavorite ? "heart.slash" : "heart"
                    )
                }
            } label: {
                // ツールバーの記号はアクセント色にしない（仕様 1.1 章）。
                // `Color.primary` は固定のラベル色で背景に追従しないので、前景色を直に渡す（仕様 1.2 章）。
                Image(systemName: "ellipsis")
                    .foregroundStyle(palette.foreground)
            }
            .accessibilityLabel(
                isPlaylist ? String(localized: "プレイリストの操作") : String(localized: "アルバムの操作")
            )
            .disabled(tracks.isEmpty)
        }
    }

    private func load() async {
        tracks = await library.tracks(for: album)
        isLoading = false
    }
}

/// 行の同一性に罫線の色を混ぜるための鍵。`listRowSeparatorTint` は行ができた時点の色で貼られ、
/// あとからアートワークの色が届いても、使い回されたセルには貼り直されない
/// （アルバムを次々に開く経路で、既定の灰色のまま残るのを撮って確かめた）。
/// 色が変わったら別の行として作り直させることで、指定した色が必ず出る。
private struct RowKey: Hashable {
    let id: String
    let separator: Color

    init(_ id: String, _ separator: Color) {
        self.id = id
        self.separator = separator
    }
}

/// 無効なボタンの見た目を様式に任せないための器。`makeBody` が `isEnabled` を読まないので減光が入らない。
/// 既定の様式は無効なボタン全体を約 53% で描き、記号に指定した 40% の上へもう一段重なる。
/// 薄さの度合いは「ダウンロードが無いことを形で示す」こちら側の決めなので、
/// 二重に掛かった結果ではなく指定した値がそのまま出る必要がある（仕様 7 章）。
private struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

#Preview {
    NavigationStack {
        AlbumDetailView(album: MediaItem(id: "preview", name: "Preview Album", type: .musicAlbum))
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
}
