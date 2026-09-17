import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// フルプレイヤー。`.large` 固定の sheet に `docs/ui-spec.md` 4 章の高さ配分で並べる。
/// ログイン・設定と同じ背景を保ち、再生操作の主従は塗りではなくグリフの大きさで示す。
struct NowPlayingView: View {
    private enum ContentMode { case artwork, lyrics, queue }

    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var minimumTitleHeight = 76.0
    @ScaledMetric(relativeTo: .caption) private var minimumSeekHeight = 64.0
    /// iPad の音量記号（仕様 6.2 章）。参照の字面はこちらの `.caption`（12 pt）より大きく、
    /// 比から 14 pt に当たる。固定値にすると文字サイズ設定に付いてこないので `@ScaledMetric` で持つ。
    @ScaledMetric(relativeTo: .caption) private var padVolumeGlyphSize = 14.0

    /// シークが成立している間だけシステムの対話的な終了を止める（仕様 4.1 章）。
    /// 抑止を掛けるのは sheet を出している `RootView` 側なので、この状態だけ外に持たせて共有する。
    /// 再生側の状態ではないので `PlaybackEngine` には置かない。
    @Binding var isScrubbing: Bool
    /// 閉じる経路。iPhone は UIKit のカスタム提示なので SwiftUI の `dismiss` が届かず、
    /// 提示している側の状態を落としてもらうしかない（仕様 4.1.1 章）。
    let close: () -> Void

    @State private var mode: ContentMode = .artwork
    /// 上部の切り替えが動いている間だけ true。歌詞の初回位置合わせをここが下りるまで待たせる（仕様 5.1 章）。
    /// 上部が動いている最中に本文まで自分でスクロールすると、二つの動きが重なって読む位置を見失う。
    @State private var isTopTransitioning = false
    /// 切り替えごとに増やす世代。連打したとき、古い切り替えの完了処理が後から届いて
    /// 新しい遷移の途中で待ちを解いてしまうのを防ぐ。
    @State private var transitionGeneration = 0
    /// 歌詞を読み進めている間だけ操作帯を退避させる（仕様 5.1 章 第 4 版）。
    /// 判定は歌詞本文が持ち、ここは受け取った結果を帯の位置へ反映するだけにする。
    /// キューは第 3 版のまま常時表示なので、`mode == .lyrics` と併せてしか効かせない。
    @State private var lyricsControlsHidden = false
    @State private var scrubTime = 0.0
    /// 確定させたシーク先。指を離した直後は 0.2 秒間隔の時刻監視がまだ**古い再生位置**を流してくるので、
    /// 実際の再生位置がここへ追いつくまでは表示側を正とする。`Player/` を触らずに吸収するための状態。
    @State private var pendingSeekTime: TimeInterval?
    /// キュー内の `MediaItem` はお気に入りの変更を追わないので、サーバーの確定値をここに持つ。
    @State private var favoriteTrack: MediaItem?
    @State private var isUpdatingFavorite = false

    /// 提示領域の上端からアートワークまで 35 pt（仕様 4 章）。
    /// もとは自前のグラバー（上余白 10 ＋ 高さ 5）の下端から 20 という組み立てだったが、
    /// 指示子をシステムに任せた今は 35 を直接の値として持つ。指示子の寸法から引き算し直さない。
    private static let artworkTopInset: CGFloat = 35
    /// アートワークの下に残す空き。帯の高さから一辺を引くときの残りで、上下で使う値を一箇所に持つ。
    private static let artworkBottomInset: CGFloat = 12

    /// 一辺 `side` で描くのに要する帯の高さ。`artwork(width:height:)` の逆算。
    /// 帯の配分側と描画側で 35 / 12 を別々に書くと、片方だけ動かしたときに一辺が静かに縮む。
    private static func mediaHeight(forArtworkSide side: CGFloat) -> CGFloat {
        side + artworkTopInset + artworkBottomInset
    }
    /// 3 状態の切り替え（仕様 5.1 章）。`.snappy` は `extraBounce: 0` を渡しても基礎の弾みが残り、
    /// 縮みながら動く画像だと行き過ぎて戻る揺れが見えるので使わない。
    /// **0.35 秒は Musicfin の決定値で、Apple 実機を実測した値ではない。**
    private static let modeTransition: Animation = .smooth(duration: 0.35, extraBounce: 0)
    /// 操作帯の出し入れ（仕様 5.1 章 第 4 版）。3 状態の切り替えとは**別の速さ**で、
    /// `docs/org/lyrics-control.mov` を 1 枚ずつ当てて測った値に合わせてある。
    /// 出す動きは臨界制動のばねで ω ≒ 16 rad/s、`2π/ω = 0.39` 秒（当てはめ残差 0.003）。
    /// SwiftUI の `duration` はそのまま `2π/ω` なので 0.4 秒で並ぶ。
    /// **引く側も同じ 0.4 秒を使う**。録画の実測は 0.12 秒だが、実機ではそれだと視線が追い付かず、
    /// 帯が消えたというより落ちたように見えた。往復で速さが違うと、同じ 1 つの帯の出し入れが
    /// 別々の仕掛けに見えてしまうので、向きで値を変えるのはやめて 1 つに揃える。
    private static let controlsTransition: Animation = .smooth(duration: 0.4, extraBounce: 0)

    /// 配色を取り出すためだけに頼む画像の一辺。画面に出す大きさとは別に決める。
    /// 走査は 32×32 まで縮めてから行うので大きな画像は要らず、一方で画面側の一辺は
    /// `GeometryReader` の中でしか決まらないため、ここから同じ値を渡してキャッシュを共有できない。
    /// 固定にしておくと iPhone と iPad で同じ色になる利点もある（仕様 1.2 章 手順 1）。
    /// `RootView` が提示領域の地を同じ色で塗るので、そちらからも同じ値を引けるように公開する。
    static let paletteArtworkSize: CGFloat = 120

    /// アートワーク・歌詞・キューの 3 状態を 1 つのルートで囲み、そこへ背景を敷く（仕様 1.2 章）。
    /// 歌詞とキューに別の背景を持たせないのと、同じ曲のまま状態を切り替えても
    /// 色を取り出し直さないのは、どちらもこの位置に置くことで自然に満たされる。
    /// 前景はこの 3 画面では常に白なので反転の判定は要らないが、下部の選択中のボタンだけは
    /// 円の地と記号の両方を配色から引くので、背景以外にも配色そのものを下へ渡す。
    /// **地は不透明のまま**にする。半透明にすると sheet の下のアルバム詳細が本文に重なって読めなくなる。
    /// iPad は幅 519 pt の固定カラムへ収める別の組みになる（仕様 6.2 章）。寸法を決める前に
    /// 経路を分けるので、帯の比率配分も `PlayerTopLayout` の見出し化も iPad では通らない。
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        GeometryReader { geometry in
            if isPad {
                padPlayer(geometry: geometry)
            } else {
                // 背景と前景が同じ操作帯の距離を使えるよう、配分は背景を敷く手前で一度だけ決める。
                let artworkSide = geometry.size.width - 48
                let layout = PlayerLayout(
                    height: geometry.size.height,
                    artworkMedia: Self.mediaHeight(forArtworkSide: artworkSide),
                    titleMinimum: minimumTitleHeight,
                    seekMinimum: minimumSeekHeight
                )
                let controlsInset = layout.controlsHeight + geometry.safeAreaInsets.bottom
                ArtworkBackdrop(item: player.currentItem, band: .player, artworkSize: Self.paletteArtworkSize) {
                    palette in
                    ControlsTransition(
                        // モード自体の 0.35 秒ではなく、この状態を変えた 0.4 秒の transaction だけで帯を動かす。
                        progress: lyricsControlsHidden ? 0 : 1,
                        controlsInset: controlsInset,
                        safeAreaInset: geometry.safeAreaInsets.bottom
                    ) { progress, detailExtra, controlsOffset in
                        content(
                            palette: palette,
                            artworkSide: artworkSide,
                            layout: layout,
                            controlsInset: controlsInset,
                            controlsProgress: progress,
                            detailExtra: detailExtra,
                            controlsOffset: controlsOffset
                        )
                    }
                }
            }
        }
        // iPad の fitted sheet が理想寸法を読めるよう、寸法指定はルートの読み取り器より外へ置く（6 章）。
        .frame(idealWidth: 560, maxWidth: .infinity, idealHeight: 800)
    }

    // MARK: - iPad のフルプレイヤー

    /// iPad は 4 画面すべてを**幅 519 pt の固定カラム**で組む（仕様 6.2 章）。iPhone 側の
    /// `PlayerLayout` は高さの比率で帯を配るが、参照の iPad は高さが変わっても帯を伸ばさず、
    /// 実測の絶対位置にそのまま置いてある。比率で近づけようとしても縦の刻みが合わないので、
    /// ここは座標を直に置く別経路にする。
    ///
    /// 座標の原点は **window の左上**。実測値が safe area の内側ではなく window から測った値なので、
    /// 枠を window 全体まで広げてから位置を決める。
    private func padPlayer(geometry: GeometryProxy) -> some View {
        // 曲が無いときは参照の地の色も漸変の形も再生中と別なので、帯ごと切り替える（仕様 6.2.1 章）。
        // iPhone 側（`band: .player`）には参照が無いので触らない。
        let band: ArtworkPalette.Band = player.currentItem == nil ? .emptyPlayer : .player
        return ArtworkBackdrop(item: player.currentItem, band: band, artworkSize: Self.paletteArtworkSize) { palette in
            GeometryReader { window in
                padContent(palette: palette, size: window.size)
            }
            .ignoresSafeArea()
        }
    }

    private func padContent(palette: ArtworkPalette, size: CGSize) -> some View {
        // 本文（歌詞・キュー）を出すとカラムは左へ寄り、アートワークが 379 pt へ縮む。
        // `mode` は `switchMode(to:)` の `withAnimation` の中で変わるので、ここで作る座標も
        // そのまま補間される——iPhone 側の `PlayerTopLayout` のような自前の補間は要らない。
        let showsPanel = mode != .artwork
        let columnLeft = showsPanel ? PadPlayer.columnLeft : (size.width - PadPlayer.columnWidth) / 2
        return ZStack(alignment: .topLeading) {
            if showsPanel {
                padPanel
                    .frame(
                        width: max(1, size.width - PadPlayer.panelLeft - PadPlayer.panelTrailing),
                        height: size.height,
                        alignment: .top
                    )
                    .offset(x: PadPlayer.panelLeft)
                    .transition(.opacity)
            }
            padColumn(showsPanel: showsPanel)
                .frame(width: PadPlayer.columnWidth, height: size.height, alignment: .topLeading)
                .offset(x: columnLeft)
            // 下段の 3 記号だけは window 全幅の別の行で、カラムが左へ寄っても動かない（仕様 6.2 章）。
            padBottomControls(palette: palette)
                .frame(width: size.width, height: PadPlayer.rowHeight, alignment: .topLeading)
                .offset(y: PadPlayer.bottomRowTop)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .foregroundStyle(.white)
        // 地は常に暗いので、明るい外観でも文字と記号は白のままにする（仕様 1.2 章）。
        .environment(\.colorScheme, .dark)
        .tint(.pink)
        // iPad の参照はグラバーが y 38.0..43.0 に出る（窓中央 683.0 / 60×5 pt の実測。
        // 仕様 6.2 章）。iPhone の 5 とは別の値で、同じにすると 33 pt 高く付く。
        .overlay(alignment: .top) { grabber(top: 38) }
        .accessibilityAction(.escape) { close() }
        .modifier(
            PlaybackObservers(
                pendingSeekTime: $pendingSeekTime,
                isScrubbing: $isScrubbing,
                favoriteTrack: $favoriteTrack
            )
        )
    }

    /// カラムの中身。y は仕様 6.2 章の表の実測値をそのまま置く。
    private func padColumn(showsPanel: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            padArtwork(showsPanel: showsPanel)
                .offset(y: PadPlayer.mediaTop)
            // 曲名とアーティストはカラムの左端に揃え、右端にはお気に入りとメニューを置く。
            // 参照でも曲名帯の右端に 32 pt の丸が 2 個あり、中心はカラム右端から 16 / 64 pt 内側。
            // どちらがどの操作かは画像からは読めないので、iPhone と同じ順で置いている。
            songTitle
                .frame(width: PadPlayer.textWidth, alignment: .leading)
                .offset(y: PadPlayer.titleTop)
            songArtist
                .frame(width: PadPlayer.textWidth, alignment: .leading)
                .offset(y: PadPlayer.artistTop)
            HStack(spacing: PadPlayer.trailingActionSpacing - PadPlayer.rowHeight) {
                favoriteButton
                trackMenuButton
            }
            .frame(width: PadPlayer.trailingActionsFrameWidth, alignment: .trailing)
            .offset(y: PadPlayer.titleTop)

            seekControls
                .frame(width: PadPlayer.columnWidth)
                .offset(y: PadPlayer.seekTop)
            padTransport
                .offset(y: PadPlayer.transportTop)
            volumeRow
                .frame(width: PadPlayer.columnWidth, height: PadPlayer.rowHeight)
                .offset(y: PadPlayer.volumeCenter - PadPlayer.rowHeight / 2)
        }
    }

    /// アートワーク。本文を出すと 519 → 379 pt へ縮み、519 pt の帯の中で上下左右 70 pt 均等になる。
    /// 曲が無いときは参照が 377.5 pt 角なので、そこだけ三つめの寸法を使う（仕様 6.2 章）。
    private func padArtwork(showsPanel: Bool) -> some View {
        let isEmpty = player.currentItem == nil
        let side: CGFloat =
            if showsPanel {
                PadPlayer.compactArtworkSide
            } else if isEmpty {
                PadPlayer.emptyArtworkSide
            } else {
                PadPlayer.columnWidth
            }
        return Button {
            switchMode(to: .artwork)
        } label: {
            ArtworkView(
                item: player.currentItem,
                size: side,
                cornerRadius: Self.artworkCornerRadius(forSide: side, bigSide: PadPlayer.columnWidth),
                // 大きな枠では既定の 0.32 だと記号が参照より小さい。曲が無いときだけ参照の比を渡す。
                iconScale: isEmpty ? PadPlayer.emptyIconScale : 0.32,
                // 参照の四角は地を暗くする面。既定の `.quaternary` は白の加算なので空状態だけ差し替える。
                placeholderFill: isEmpty
                    ? AnyShapeStyle(.black.opacity(PadPlayer.emptyPlaceholderDarkening))
                    : AnyShapeStyle(.quaternary)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("アートワークへ戻る")
        .accessibilityHidden(mode == .artwork)
        .frame(width: PadPlayer.columnWidth, height: PadPlayer.mediaHeight)
        // 曲が無いときは上の 377.5 pt が参照の実測そのものなので、90 % 縮小（§4）を重ねない。
        // 曲があって一時停止しているときは参照が無く判定できないため、iPhone と同じ扱いを続ける。
        .scaleEffect(reduceMotion || player.isPlaying || showsPanel || isEmpty ? 1 : 0.9)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: player.isPlaying)
    }

    /// 参照の iPad はトランスポートが **5 記号**で、両端に shuffle と repeat が付く（仕様 6.2 章）。
    /// 中心間は等間隔ではなく、前・再生・次が 96.75 pt、shuffle と repeat はそこから約 148.9 pt
    /// 外側にある。中央の再生を基準に実測の中心をそのまま置く。
    /// 曲が無いときは参照が**前・再生・次の 3 記号だけ**で、両端の 2 記号は淡くなるのではなく
    /// 描かれない。前後送りは淡色、再生だけ白のままなので、行ごとではなく前後送りだけを止める。
    private var padTransport: some View {
        let isEmpty = player.currentItem == nil
        return ZStack {
            if !isEmpty {
                shuffleButton.offset(x: -PadPlayer.transportOuterOffset)
            }
            previousButton.offset(x: -PadPlayer.transportInnerSpacing).disabled(isEmpty)
            // 掛ける曲が無ければ `PlaybackEngine.play()` 側が何もしないので、見た目だけ白に保つ。
            playPauseButton
            nextButton.offset(x: PadPlayer.transportInnerSpacing).disabled(isEmpty)
            if !isEmpty {
                repeatButton.offset(x: PadPlayer.transportOuterOffset)
            }
        }
        // 両端の枠がカラムの外へ 8 pt ずつ出るので、行はカラムより広い 535 pt で持つ。
        .frame(width: PadPlayer.transportWidth, height: PadPlayer.transportHeight)
        .offset(x: -(PadPlayer.transportWidth - PadPlayer.columnWidth) / 2)
    }

    /// 下段の 3 記号。参照は **AirPlay が左**で、歌詞とキューが右端へ寄る（仕様 6.2 章）。
    /// iPhone の「歌詞 / AirPlay / キュー」の並びとは別物なので `bottomControls` は使わない。
    private func padBottomControls(palette: ArtworkPalette) -> some View {
        ZStack(alignment: .topLeading) {
            AudioRouteView()
                .frame(width: PadPlayer.rowHeight, height: PadPlayer.rowHeight)
                .accessibilityLabel("出力先")
                .offset(x: PadPlayer.routeGlyphCenter - PadPlayer.rowHeight / 2)
            modeButton(.lyrics, symbol: "quote.bubble", label: "歌詞", palette: palette)
                .offset(x: PadPlayer.lyricsGlyphCenter - PadPlayer.rowHeight / 2)
            modeButton(.queue, symbol: "list.bullet", label: "次に再生", palette: palette)
                .offset(x: PadPlayer.queueGlyphCenter - PadPlayer.rowHeight / 2)
        }
    }

    /// 右の面。iPad はカラムが横に並ぶので、歌詞を読んでいる間も操作を退避させない
    /// （`onControlsVisibilityChange` を捨てているのはそのため）。
    @ViewBuilder
    private var padPanel: some View {
        switch mode {
        case .artwork:
            EmptyView()
        case .lyrics:
            if let track = player.currentItem {
                LyricsView(
                    track: track,
                    isSettled: !isTopTransitioning,
                    bottomExtension: 0,
                    onControlsVisibilityChange: { _ in }
                )
                .id(track.id)
            }
        case .queue:
            // 現在の曲は左のカラムが出しているので、面の側には見出しを重ねない。
            QueueView()
        }
    }

    private func content(
        palette: ArtworkPalette,
        artworkSide: CGFloat,
        layout: PlayerLayout,
        controlsInset: CGFloat,
        controlsProgress: CGFloat,
        detailExtra: CGFloat,
        controlsOffset: CGFloat
    ) -> some View {
        // 外側の `ScrollView` も、シーク以降の 4 帯も **3 状態で同じものを使い回す**（仕様 5.1 章）。
        // 以前は状態ごとに構成ごと組み替えていたが、それだと外側が入れ替わるたびに操作帯まで
        // 挿入・削除として消えて現れ、上部が動く裏で画面全体がちらつく。
        // 組み替えるのは上部の配置だけにする。
        // 歌詞を読み進めている間だけ操作帯を画面外へ逃がす（仕様 5.1 章 第 4 版）。
        let controlsHidden = mode == .lyrics && lyricsControlsHidden
        // 本文の下端は、帯の見えている上端へ毎フレーム接続する（仕様 5.1 章 第 6 版）。
        // 二値で遅らせると、短い反転では待ちが完了せず、消えた帯の全高が空白として残る。
        // 同じ補間値から本文の延長量と帯の見た目を作れば、向きを変えても途中の位置から連続する。
        return ScrollView {
            topArea(
                artworkSide: artworkSide,
                layout: layout,
                detailExtra: detailExtra,
                controlsInset: controlsInset
            )
            // 重ねた操作帯を通常時の全高へ含め、文字拡大時の外側スクロール範囲は変えない。
            // 歌詞本文だけが `detailExtra` ではみ出すため、上部の高さと位置はこの枠でも動かない。
            .frame(height: layout.media + layout.title + layout.controlsHeight, alignment: .top)
            .overlay(alignment: .bottom) {
                // シーク以降の 4 帯は **1 つの塊にまとめ、3 状態で同じものを保つ**（仕様 5.1 章 第 4 版）。
                // 上部との `VStack` に置くと、見た目を 0 まで畳んでも元の高さが兄弟領域として残り、
                // はみ出して伸ばした歌詞本文がその場所を実際の表示領域として使えない。
                // 通常時と同じ位置へ重ねれば identity と高さを保ったまま、本文へ場所を譲れる。
                VStack(spacing: 0) {
                    seekControls.frame(height: layout.seek)
                    transport.frame(height: layout.transport)
                    // 音量は帯の下端へ、下部の記号は帯の上端へ寄せる。この 2 つを中央に置いたままだと
                    // 音量記号から選択円までが (volume + bottom) / 2 で決まってしまい、
                    // 最小値だけで目標を 15 pt 超えるので比率をいくら下げても届かない（仕様 4 章）。
                    // 寄せるのは 44 pt の操作行ごとで、記号だけを動かすのではない。
                    volumeRow.frame(height: layout.volume, alignment: .bottom)
                    bottomControls(palette: palette).frame(height: layout.bottom, alignment: .top)
                }
                // 退避と復帰は**縦だけ 0 と 1 の間で伸縮させる**。隠れている間の見た目の高さは 0 で、
                // 戻るときは下端を置いたまま上へ育って通常の高さになる。横は縮めない——
                // 幅まで縮むと帯が中央へ吸い込まれる別の動きに見え、4 帯が横に並ぶ組みが崩れて見える。
                // 下端を基準にするのは参照録画の実測（伸びている間、帯の下端はほぼ動かない）。
                .scaleEffect(x: 1, y: controlsProgress, anchor: .bottom)
                // 伸び縮みと**同じ速さで濃さも動かす**。参照録画では高さが 5 割の時点で
                // まだ半透明で、縦の伸びだけだと畳まれた帯の輪郭が最初から出てしまう。
                .opacity(controlsProgress)
                // 下端基準の縮小だけで帯本体の退避量は作れるので、ここで重ねるのは安全域だけにする。
                // 本文と同じ全量をずらすと帯本体の高さを二重に数え、両者の間へ空白が残る。
                .offset(y: controlsOffset)
                // 見えない操作を押せたり読み上げられたりしないようにする。位置だけずらしても残るため。
                .allowsHitTesting(!controlsHidden)
                .accessibilityHidden(controlsHidden)
            }
            .padding(.horizontal, 24)
        }
        // 中身は通常ちょうど画面の高さなので、ここは余分に動かない。文字を大きくして
        // 入り切らなくなったときだけ操作部へ届く退避先になる（仕様 5.1 章）。
        // **`.scrollDisabled(true)` は付けない。**内側の歌詞・キューの本文まで無効化が伝わる。
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        // 10 pt だと上端が 72 pt に出て、仕様 4 章が記録する 67 pt より 5 pt 下がったので引いた。
        // なぜ 5 pt ずれるのかは確かめていない。この値は撮り直して測るまで確定ではない。
        .overlay(alignment: .top) { grabber(top: 5) }
        // 地が常に暗い帯になったので、明るい外観の端末でも文字と記号は白のままにする（仕様 1.2 章）。
        // 個々の `.primary` / `.secondary` を白に置き換えて回らないのは、選択中の記号が地の色へ
        // 反転する `modeButton` のように、白の指定だけでは足りない組みがあるため。
        .environment(\.colorScheme, .dark)
        // sheet はタブの tint を引き継がないので、ここで改めてピンクに揃える。
        .tint(.pink)
        // 閉じるボタンは置かない方針（仕様 4 章）なので、下スワイプの届かない VoiceOver へ
        // エスケープ操作だけは自前で用意する（仕様 4.1 章）。
        .accessibilityAction(.escape) { close() }
        .modifier(
            PlaybackObservers(
                pendingSeekTime: $pendingSeekTime,
                isScrubbing: $isScrubbing,
                favoriteTrack: $favoriteTrack
            )
        )
    }

    /// シークの着地とお気に入りの取り直し。**iPhone / iPad の両経路へ同じものを付ける**ために型にする。
    /// 以前 iPad のキューだけが別の組みで、この監視が付いていなかったため、
    /// あちらではお気に入りの星がサーバーの値を映さず、シークの表示も古い位置へ戻っていた。
    private struct PlaybackObservers: ViewModifier {
        @Environment(AuthStore.self) private var auth
        @Environment(PlaybackEngine.self) private var player
        @Binding var pendingSeekTime: TimeInterval?
        @Binding var isScrubbing: Bool
        @Binding var favoriteTrack: MediaItem?

        func body(content: Content) -> some View {
            content
                // 再生位置が目標へ追いついたら、表示の優先を再生側へ返す。
                .onChange(of: player.currentTime) { _, time in
                    guard let pending = pendingSeekTime,
                        abs(time - pending) <= NowPlayingView.seekSettleTolerance
                    else { return }
                    pendingSeekTime = nil
                }
                // 着地しなかったときの保険。これが無いと、追いつきを待ち続けて表示が止まったままになる。
                .task(id: pendingSeekTime) {
                    guard pendingSeekTime != nil else { return }
                    try? await Task.sleep(for: NowPlayingView.seekSettleTimeout)
                    guard !Task.isCancelled else { return }
                    pendingSeekTime = nil
                }
                .task(id: player.currentItem?.id) {
                    isScrubbing = false
                    // 曲が替わると目標は意味を失う。持ち越すと新しい曲の先頭で古い位置を表示してしまう。
                    pendingSeekTime = nil
                    favoriteTrack = player.currentItem
                    guard let id = player.currentItem?.id, let client = auth.client else { return }
                    if let item = try? await client.fetchItem(id: id), !Task.isCancelled {
                        favoriteTrack = item
                    }
                }
        }
    }

    // MARK: - 上部のグラバー

    /// 上部のグラバー（仕様 4 章）。システムの指示子は 36 pt 幅で Apple 実機の 60 pt より細いので、
    /// `RootView` 側で指示子を消し、同じ 60×5 pt をここで描く。
    /// **描くのは見た目だけ**で、当たり判定もジェスチャも持たせない。閉じる操作は引き続き
    /// システムの対話的な終了が担うので、自前のドラッグを戻したことにはならない（仕様 4.1 章 第 3 版）。
    /// 色は `reference/nowplaying.png` の実測（地 (99,79,76) に対しグラバー (169,149,149)）から。
    /// 白を 0.42 で重ねると 4〜5 階調以内で合う。仕様 4 章の選択中ボタンと同じ「成分への一律加算」でも
    /// 同じくらい合うが、あちらは palette の中央 stop を前提にした規則で、グラバーが載るのは
    /// 帯の上端なので、同じ規則だと決めつけずに重ねる側で書く。
    /// - Parameter top: 上端までの余白。**iPhone と iPad で参照の y が別**（下の呼び出し側）。
    private func grabber(top: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.42))
            .frame(width: 60, height: 5)
            .padding(.top, top)
            // 触れない・読み上げない。閉じる経路は `accessibilityAction(.escape)` が持つ。
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - アートワーク / 歌詞 / キュー

    /// メディア領域と曲情報行を合わせた上部。**切り替えるのはここの配置だけ**で、高さは 3 状態で同じ（仕様 5.1 章）。
    /// 高さを固定して下の 4 帯を押し下げさせないので、あふれたぶんは歌詞・キューが自分でスクロールする。
    /// クリップを掛けるのはこの境界だけにする。内側で切ると、縮みながら動く画像が
    /// 経路の途中で切り落とされて、消えてから現れたように見える。
    ///
    /// 子は **5 つを常に同じ順序で並べ、`if` / `else` で作り分けない**。状態で変えるのは
    /// `PlayerTopLayout` に渡す `progress` だけなので、画像も曲名も状態ごとに別の View へ
    /// 差し替わらず、遷移の途中で 2 つ写ることがない（仕様 5.1 章）。
    /// 明示的なフェードを足すのは歌詞・キューの本文だけ。
    private func topArea(
        artworkSide: CGFloat,
        layout: PlayerLayout,
        detailExtra: CGFloat,
        controlsInset: CGFloat
    ) -> some View {
        // 基準は幅いっぱいで、帯の高さが足りないときだけ縮める（仕様 4 章）。
        // 帯のほうは `PlayerLayout` が一辺を先に確保しに行くので、通常は `artworkSide` で決まる。
        let bigSide = max(1, min(artworkSide, layout.media - Self.artworkTopInset - Self.artworkBottomInset))
        return PlayerTopLayout(
            progress: mode == .artwork ? 0 : 1,
            bigArtworkSide: bigSide,
            artworkTop: Self.artworkTopInset,
            mediaHeight: layout.media,
            titleHeight: layout.title,
            hasArtist: !(player.currentItem?.displayArtist ?? "").isEmpty,
            // 歌詞だけ見出しと本文を**隙間なく繋ぐ**（仕様 5.1 章）。参照では先頭行が見出しの
            // すぐ下から入って上端へ抜けていくので、ここに段があると行が途中から現れる。
            // キューは「次に再生」の見出しから始まる別の組みなので、そちらの 16 pt は残す。
            detailGap: mode == .lyrics ? 0 : PlayerTopLayout.compactBottom
        ) {
            // 並び順は `PlayerTopLayout` の添字と対応する。本文を最初に置くのは、
            // 縮んでいく画像が本文の領域を通る間、画像が上に来て文字と重なって見えないようにするため。
            detailSlot(viewportExtra: controlsInset)
            artworkSlot(bigSide: bigSide)
            songTitle
            songArtist
            favoriteButton
            trackMenuButton
        }
        .frame(height: layout.media + layout.title)
        // 切り抜きは**下だけ `detailExtra` ぶん広げる**（仕様 5.1 章 第 4 版）。`.clipped()` のままだと
        // 伸ばした本文がこの枠の下端で切り落とされ、帯を隠しても読める行が増えない。
        // 上と左右を広げないのは、縮んでいく画像がこの境界の外へ出ないようにするため。
        .clipShape(BottomExtendedRect(extra: detailExtra))
        // **切り抜きは当たり判定を決めない。**`.clipped()` も `.clipShape` も形を描くだけなので、
        // これを付けないと伸ばした領域でスクロールも行タップも効かない。切り抜きと同じ形にする。
        .contentShape(.interaction, BottomExtendedRect(extra: detailExtra))
        // **ここに `.animation(value: detailExtra)` は置かない**（仕様 5.1 章 第 4 版の差し替え）。
        // 置いていたときは、`.animation` が subtree 全体に掛かるせいで帯が動くのと同じ更新で
        // 現在行が移ると、行の濃さとぼかしまで帯の 0.4 秒のばねに乗って遅れて追い付いた。
        // 本文の高さ・切り抜き・当たり判定は**即時に**変える。補間するのは帯だけにする。
    }

    /// アートワーク。**大きさも角丸も同じ View の上で変える**ので、状態を切り替えても
    /// 画像の読み込みやプレースホルダーからのフェードは起き直らない（仕様 5.1 章）。
    /// 一辺はレイアウトが提示した枠から読む。ここで状態を見て決めると、補間の途中の値を取れない。
    private func artworkSlot(bigSide: CGFloat) -> some View {
        // **3 状態とも同じ `Button`** にする（仕様 5.1 章 第 4 版）。歌詞で操作帯が退避している間は
        // 下部の 3 ボタンが画面外にあるので、この見出しの画像だけがアートワーク状態へ戻る道になる。
        // 状態によって `Button` を付け外しすると identity が変わり、補間の途中で画像が作り直される。
        // アートワーク状態では同じ状態への切り替えになり、`switchMode(to:)` が何もしない。
        Button {
            switchMode(to: .artwork)
        } label: {
            GeometryReader { proxy in
                let side = max(1, min(proxy.size.width, proxy.size.height))
                ArtworkView(
                    item: player.currentItem,
                    size: side,
                    cornerRadius: Self.artworkCornerRadius(forSide: side, bigSide: bigSide)
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("アートワークへ戻る")
        // アートワーク状態のこれは押しても何も起きない大きな画像なので、操作として読み上げない。
        // `ArtworkView` 自体は読み上げ対象を持たず、曲名・アーティストは隣の `Text` が読まれる。
        .accessibilityHidden(mode == .artwork)
        // 停止中は 90% に縮めて「止まっている」ことを形で示す。視差効果を減らす設定なら固定。
        // 72 pt まで縮んだ状態では掛けない。小さい画像でさらに縮めても止まっていることは伝わらず、
        // 曲名との縦位置だけがずれる。
        .scaleEffect(reduceMotion || player.isPlaying || mode != .artwork ? 1 : 0.9)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: player.isPlaying)
        // 影は無彩色に替えるのではなく付けない。画像そのものを見せる（仕様 1.1 章）。
    }

    /// 角丸は一辺に従わせる。72 pt で 8 pt、大画像で 20 pt（仕様 4 章・5.1 章）。
    /// 20 pt のままで縮めると小さい画像の縁だけが不釣り合いに丸くなる。
    private static func artworkCornerRadius(forSide side: CGFloat, bigSide: CGFloat) -> CGFloat {
        let span = bigSide - PlayerTopLayout.compactArtworkSide
        guard span > 0 else { return 20 }
        let ratio = min(max((side - PlayerTopLayout.compactArtworkSide) / span, 0), 1)
        return 8 + (20 - 8) * ratio
    }

    /// 本文の置き場。中身が無いアートワーク状態でも**子の数と順序を変えない**ために、
    /// 透明な枠で場所だけ確保する（仕様 5.1 章）。
    private func detailSlot(viewportExtra: CGFloat) -> some View {
        Color.clear
            .overlay {
                detail(viewportExtra: viewportExtra).transition(.opacity)
            }
            // アートワーク状態ではこの枠に大画像が重なるので、透明な枠に操作を吸わせない。
            .allowsHitTesting(mode != .artwork)
    }

    /// 歌詞・キューの本体。アートワーク状態では出さない。
    @ViewBuilder
    private func detail(viewportExtra: CGFloat) -> some View {
        switch mode {
        case .artwork:
            EmptyView()
        case .lyrics:
            if let track = player.currentItem {
                // 内側 ScrollView は最初から最大高へ固定する。毎フレーム実 frame を変えると、
                // UIScrollView が bounds と offset を補正して drag / deceleration の速度を失う。
                // 見せる下端だけは外側の BottomExtendedRect が帯と同じ補間値で動かす。
                GeometryReader { proxy in
                    // 上部が動いている間は歌詞に位置合わせをさせない（仕様 5.1 章）。
                    LyricsView(
                        track: track,
                        isSettled: !isTopTransitioning,
                        bottomExtension: viewportExtra,
                        onControlsVisibilityChange: { setLyricsControlsHidden($0) }
                    )
                    .id(track.id)
                    .frame(height: proxy.size.height + viewportExtra, alignment: .top)
                }
            }
        case .queue:
            QueueView()
        }
    }

    // MARK: - 曲情報

    /// 曲名とアーティスト。歌詞・キューでは 72 pt のアートワーク横へ収まる大きさへ落とす。
    /// 置き場所と幅は `PlayerTopLayout` が決めるので、ここは **leading 揃えのまま**にして
    /// 揃えや余白で位置を繕わない（仕様 5.1 章）。
    /// フォントの変更は `.contentTransition(.interpolate)` に補間させる。意味のある指定
    /// （`.title2.bold()` ↔ `.headline`、`.title3` ↔ `.subheadline`）はそのまま残す。
    /// **曲名・アーティストはどちらも 1 行で、入らない分は末尾を省略する**（仕様 4 章）。
    /// Apple Music が長い曲名を折り返さないためで、**あちらの横スクロールを実測して真似たものではない**。
    /// 縮小して詰め込むと隣の状態と字の大きさが食い違うので `minimumScaleFactor` は足さない。
    /// 文字列は切らずに `Text` へ省略させる。読み上げには省略前の全文が残る。
    ///
    /// 2 行は **`VStack` でまとめず、レイアウトの別々の子として置く**。まとめていたときは
    /// 遷移の途中で曲名だけが遅れ、アーティストが上に出て 2 行が入れ替わって見えた。
    /// 録画のフレームで測ると、レイアウトが直に置くアートワーク・お気に入りと
    /// アーティストは進みが一致し、曲名だけが 0.2 付近で止まっていた
    /// （`.contentTransition` を外しても同じだったので、文字の補間が原因ではない）。
    ///
    /// さらに `.geometryGroup()` を付ける。字の大きさが変わる `Text` は、自分の寸法の変化を
    /// 祖先の位置の変化とは別に補間してしまい、レイアウトが置いた場所へ遅れて着く。
    /// 録画では画像とお気に入りが 0.43 まで進んだところで文字 2 行だけが 0.2 に居残っていた。
    /// この修飾子でジオメトリの変化をひとまとめにすると、位置はレイアウトの `progress` だけで決まる。
    private var songTitle: some View {
        // 状態で切り替えるのはフォントだけ。`Text` そのものは作り直さない。
        Text(player.currentItem?.displayName ?? String(localized: "再生していません"))
            // iPad はカラムが縮まないので、本文を出しても字の大きさを落とさない（仕様 6.2 章）。
            .font(mode == .artwork || isPad ? .title2.bold() : .headline)
            .accessibilityIdentifier("nowplaying.title")
            .accessibilityValue(player.currentItem?.id ?? "")
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(reduceMotion ? .identity : .interpolate)
            .geometryGroup()
    }

    /// アーティスト名はアクセント色にしない（仕様 4 章）。曲名に近い大きさの secondary。
    /// 曲がないときは空文字にして、**子の数を固定する**。子が増減すると
    /// `PlayerTopLayout` の添字がずれる。行として数えるかは `hasArtist` で明示的に渡す。
    private var songArtist: some View {
        Text(player.currentItem?.displayArtist ?? "")
            .font(mode == .artwork || isPad ? .title3 : .subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(reduceMotion ? .identity : .interpolate)
            .geometryGroup()
    }

    private var trackMenuButton: some View {
        Menu {
            if let track = player.currentItem {
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
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .frame(width: 32, height: 32)
                .background(.quaternary, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("曲の操作")
    }

    private var favoriteButton: some View {
        Button {
            Task { await toggleFavorite() }
        } label: {
            Image(systemName: favoriteTrack?.isFavorite == true ? "star.fill" : "star")
                .font(.title3)
                .foregroundStyle(favoriteTrack?.isFavorite == true ? AnyShapeStyle(.pink) : AnyShapeStyle(.primary))
                // 見える円は直径 32 pt、操作領域は 44 pt（仕様 4 章）。地と当たり判定を別の枠で持つ。
                .frame(width: 32, height: 32)
                .background(.quaternary, in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(favoriteTrack == nil || isUpdatingFavorite)
        .accessibilityLabel(
            favoriteTrack?.isFavorite == true
                ? String(localized: "お気に入りから削除") : String(localized: "お気に入りに追加")
        )
    }

    // MARK: - シーク

    /// 追いついたと見なす差。時刻監視が 0.2 秒間隔なので、着地の遅れを足しても普通はこの内に収まる。
    /// これより細かいずれは 4 分の曲で 1 pt 未満の位置差にしかならず、表示としては区別が付かない。
    private static let seekSettleTolerance: TimeInterval = 0.5
    /// 追いつきを待つ上限。回線や HLS の都合でシークが着地しないときの保険で、待ち時間ではなく上限。
    private static let seekSettleTimeout: Duration = .seconds(3)

    /// 指の位置 → 確定したシーク先 → 実際の再生位置、の順に優先する。
    private var displayedTime: TimeInterval {
        if isScrubbing { return scrubTime }
        return pendingSeekTime ?? player.currentTime
    }

    /// シークを確定させ、再生位置が追いつくまでの表示を引き受ける。`player.seek(to:)` と同じ切り詰めを
    /// ここでもするのは、尺の外を指したときに目標へ永遠に届かず表示が固まるのを避けるため。
    private func commitSeek(to time: TimeInterval) {
        let clamped = min(max(time, 0), max(player.duration, 0))
        pendingSeekTime = clamped
        player.seek(to: clamped)
    }

    private var seekControls: some View {
        // バーの当たり判定 44 pt は 6 pt の線の下に 19 pt の透明な余白を残すので、時刻がその分だけ落ちる。
        // 時刻だけを 8 pt 引き上げ、同じだけ下に余白を戻してブロック全体の高さ（＝バーの位置）は変えない。
        VStack(spacing: -8) {
            PlayerSeekBar(
                value: displayedTime,
                duration: player.duration,
                isScrubbing: isScrubbing,
                onChanged: { value in
                    scrubTime = value
                    isScrubbing = true
                },
                onEnded: { value in
                    scrubTime = value
                    isScrubbing = false
                    commitSeek(to: value)
                },
                // システムに取り消されたら、掴んだ値は捨てて現在の再生位置の表示へ戻す（仕様 4.2 章）。
                onCancelled: { isScrubbing = false },
                // 連続して調整したときに差分が積み上がるよう、起点は再生位置ではなく表示している位置にする。
                adjust: { offset in commitSeek(to: displayedTime + offset) }
            )
            HStack {
                Text(elapsedLabel)
                Spacer()
                Text(remainingLabel)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
        // シークバーも曲名と同じ左右 32 pt に揃える（仕様 4 章）。iPad はカラムの幅が
        // そのままバーの幅（519 pt）なので足さない（仕様 6.2 章）。
        .padding(.horizontal, isPad ? 0 : 8)
    }

    /// 曲が無いときの経過・残り。0 秒として `0:00` / `-0:00` を出すと止まっている位置を
    /// 持っているように見えるので、参照と同じく両側を `--:--` にする（仕様 6.2 章）。
    private var elapsedLabel: String {
        player.currentItem == nil ? TimeInterval.nan.timeLabel : displayedTime.timeLabel
    }

    /// 残り側も参照はマイナスを付けず `--:--` なので、`remainingLabel` は通さない。
    private var remainingLabel: String {
        player.currentItem == nil
            ? TimeInterval.nan.timeLabel
            : max(0, player.duration - displayedTime).remainingLabel
    }

    // MARK: - 再生操作

    private var transport: some View {
        // 記号の輪郭の中心どうしが Apple 実機で 106.8 pt。字形に依らない量として測れたのでそれに合わせる。
        // 以前の 61 は端末幅 430 pt を仮定した概算で、実測ではこの間隔が 9.7 pt 広かった。
        HStack(spacing: 51) {
            previousButton
            playPauseButton
            nextButton
        }
        .disabled(player.currentItem == nil)
        .frame(maxWidth: .infinity)
    }

    private var previousButton: some View {
        Button {
            player.playPrevious()
        } label: {
            Image(systemName: "backward.fill")
                .font(.system(size: isPad ? PadPlayer.skipGlyphSize : 30, weight: .semibold))
                // 塗りのない記号なので、当たり判定の 44 pt を形で明示する。
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel("前の曲")
    }

    private var playPauseButton: some View {
        Button {
            player.toggle()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: isPad ? PadPlayer.playGlyphSize : 48, weight: .semibold))
                .frame(width: 64, height: 64)
                .overlay(alignment: .bottom) {
                    if player.isBuffering {
                        ProgressView().controlSize(.mini).tint(.primary).padding(.bottom, 8)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? String(localized: "一時停止") : String(localized: "再生"))
    }

    private var nextButton: some View {
        Button {
            player.playNext()
        } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: isPad ? PadPlayer.skipGlyphSize : 30, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(TransportButtonStyle())
        .disabled(!player.hasNext)
        .accessibilityLabel("次の曲")
    }

    /// iPad の両端の 2 記号（仕様 6.2 章）。iPhone には出ない記号なので、指定は iPad の実測だけ。
    private var shuffleButton: some View {
        Button {
            player.toggleShuffle()
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: PadPlayer.sideGlyphSize, weight: .semibold))
                .foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("シャッフル")
        .accessibilityValue(player.isShuffled ? String(localized: "オン") : String(localized: "オフ"))
        .accessibilityAddTraits(player.isShuffled ? .isSelected : [])
    }

    private var repeatButton: some View {
        Button {
            player.cycleRepeatMode()
        } label: {
            Image(systemName: player.repeatMode.systemImage)
                .font(.system(size: PadPlayer.sideGlyphSize, weight: .semibold))
                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("リピート")
        .accessibilityValue(repeatDescription)
        .accessibilityAddTraits(player.repeatMode == .off ? [] : .isSelected)
    }

    private var repeatDescription: String {
        switch player.repeatMode {
        case .off: String(localized: "オフ")
        case .all: String(localized: "すべての曲")
        case .one: String(localized: "1 曲")
        }
    }

    // MARK: - 音量

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            SystemVolumeView()
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .accessibilityLabel("音量")
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(isPad ? .system(size: padVolumeGlyphSize) : .caption)
        .foregroundStyle(.secondary)
        // 曲名やシークと同じ左右 32 pt へ揃える（仕様 5 章）。外側の 24 pt との差を足す。
        // iPad はカラムの幅がそのまま行の幅になるので足さない（仕様 6.2 章）。
        .padding(.horizontal, isPad ? 0 : 8)
    }

    // MARK: - 下部（歌詞 / 出力先 / キュー）

    private func bottomControls(palette: ArtworkPalette) -> some View {
        HStack {
            modeButton(.lyrics, symbol: "quote.bubble", label: "歌詞", palette: palette)
            Spacer()
            AudioRouteView()
                .frame(width: 44, height: 44)
                .accessibilityLabel("出力先")
            Spacer()
            modeButton(.queue, symbol: "list.bullet", label: "次に再生", palette: palette)
        }
        // 左右の操作の中心を端から約 82 pt に置く（仕様 4 章）。外側の 24 pt と合わせて 60 pt。
        .padding(.horizontal, 36)
    }

    /// 選択中は直径 38 pt の明るい円を地に敷き、記号を暗色へ反転させる（仕様 4 章）。
    /// 円も記号も配色から引くのは、白と黒の固定色だと帯の色が変わっても円だけ同じ明るさで残り、
    /// 画面の中でここだけ無彩色に浮くため。円は背景に 0.45 を足した色、記号は背景そのもの。
    /// 色だけで選択を示さない一方、当たり判定の 44 pt は外側の枠で保つ。
    private func modeButton(
        _ target: ContentMode,
        symbol: String,
        label: LocalizedStringResource,
        palette: ArtworkPalette
    ) -> some View {
        let isSelected = mode == target
        return Button {
            switchMode(to: isSelected ? .artwork : target)
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(palette.selectedModeForeground) : AnyShapeStyle(.secondary)
                )
                .frame(width: 38, height: 38)
                .background {
                    if isSelected { Circle().fill(palette.selectedModeFill) }
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 帯と本文は同じ補間値で動くため、ここでは目標だけを切り替える（仕様 5.1 章 第 6 版）。
    /// 途中で向きが変わっても SwiftUI が現在の提示値から次の目標へ補間し直す。
    private func setLyricsControlsHidden(_ hidden: Bool) {
        guard lyricsControlsHidden != hidden else { return }
        if reduceMotion {
            lyricsControlsHidden = hidden
        } else {
            withAnimation(Self.controlsTransition) { lyricsControlsHidden = hidden }
        }
    }

    /// 状態を切り替え、上部の遷移が終わってから歌詞の位置合わせを許す（仕様 5.1 章）。
    /// 世代と現在のモードの両方を確かめてから待ちを解くのは、連打したときに古い切り替えの
    /// 完了処理が後から届き、まだ動いている新しい遷移の途中で歌詞を跳ばせてしまうため。
    private func switchMode(to next: ContentMode) {
        // 見出しのアートワークはアートワーク状態でも押せる（仕様 5.1 章 第 4 版）ので、
        // 同じ状態への切り替えが来る。遷移を始めてしまうと、動かない画面のまま待ちだけが立つ。
        guard next != mode else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        // 歌詞を離れたら操作帯は出した状態へ戻す（仕様 5.1 章 第 4 版）。歌詞で隠したまま移ると、
        // 判定を持たないキューやアートワークで操作が消えたきりになる。
        // 「視差効果を減らす」設定では位置・大きさを補間しないので、待たせる理由もない（仕様 5.1 章）。
        guard !reduceMotion else {
            mode = next
            lyricsControlsHidden = false
            isTopTransitioning = false
            return
        }
        isTopTransitioning = true
        // 操作帯の復帰は出し入れ固有の 0.4 秒を保つ。モードの 0.35 秒へ同居させると、
        // 歌詞から離れる経路だけ復帰速度が変わり、通常の表示操作と別の帯に見える。
        withAnimation(Self.controlsTransition) { lyricsControlsHidden = false }
        withAnimation(Self.modeTransition) {
            mode = next
        } completion: {
            guard transitionGeneration == generation, mode == next else { return }
            isTopTransitioning = false
        }
    }

    private func toggleFavorite() async {
        guard let track = favoriteTrack else { return }
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }
        await library.toggleFavorite(track)
        guard let client = auth.client,
            let updated = try? await client.fetchItem(id: track.id),
            player.currentItem?.id == track.id
        else { return }
        favoriteTrack = updated
    }
}

/// Apple Music と同じく通常時はつまみを隠し、ドラッグ中だけ小さく示すシークバー。
private struct PlayerSeekBar: View {
    let value: TimeInterval
    let duration: TimeInterval
    let isScrubbing: Bool
    let onChanged: (TimeInterval) -> Void
    let onEnded: (TimeInterval) -> Void
    /// 成立後の取り消し。確定させずにプレビューだけ畳む（仕様 4.2 章）。
    let onCancelled: () -> Void
    let adjust: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let progress = duration > 0 ? min(max(value / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                // 線の輪郭を実測すると Apple 実機は 21px ＝ 7 pt。音量のバーとは同じ太さで揃える。
                Capsule().fill(.secondary.opacity(0.28)).frame(height: 7)
                Capsule().fill(.primary.opacity(0.55)).frame(width: geometry.size.width * progress, height: 7)
                if isScrubbing {
                    Circle()
                        .fill(.primary)
                        .frame(width: 10, height: 10)
                        .offset(x: geometry.size.width * progress - 5)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                SeekGesture(
                    onChanged: { point in
                        if let time = time(at: point.x, width: geometry.size.width) { onChanged(time) }
                    },
                    onEnded: { point in
                        if let time = time(at: point.x, width: geometry.size.width) { onEnded(time) }
                    },
                    onCancelled: onCancelled
                )
            )
        }
        .frame(height: 44)
        // VoiceOver の調整には方向も距離も課さない（仕様 4.2 章）。認識器は本文の側にしか付いていない。
        .accessibilityElement()
        .accessibilityLabel("再生位置")
        .accessibilityValue(value.timeLabel)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(10)
            case .decrement: adjust(-10)
            @unknown default: break
            }
        }
    }

    /// 再生時間が無効なら `nil`。`disabled` では UIKit の認識器まで止まるとは限らないので、
    /// 「受け付けない」（仕様 4.2 章）は換算のここで断つ。0 を返すと先頭へシークしてしまう。
    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval? {
        guard duration > 0, width > 0 else { return nil }
        return duration * min(max(x / width, 0), 1)
    }
}

/// シークバーの当たり判定にだけ付ける認識器。方向の選別は `SeekGestureRecognizer` が持ち、
/// ここは成立した状態遷移を呼び出し側の 3 つの処理へ振り分けるだけにする。
/// `.failed` では UIKit が動作を送らないので、認識前の取り消しは自然に「何もしない」になる。
private struct SeekGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> SeekGestureRecognizer {
        SeekGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: SeekGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began, .changed: onChanged(location)
        case .ended: onEnded(location)
        case .cancelled: onCancelled()
        default: break
        }
    }
}

/// 横ドラッグだけをシークとして成立させ、縦ドラッグは認識を**失敗**させてスクロールへ渡す（仕様 4.2 章）。
/// SwiftUI の `DragGesture` を使わないのは、`onChanged` で更新を止めても成立済みの認識は残り、
/// 本文の縦スクロールを奪ったままになるため。失敗へ落とせるのは UIKit 側の認識器だけ。
/// `private` にしないのは、終了 pan がこの型の失敗を待つ依存を作るため（仕様 4.1.1 章）。
final class SeekGestureRecognizer: UIGestureRecognizer {
    /// 方向を判定するまでの待機量と、横と認める比。**このアプリの操作上の決定値**であり、
    /// Apple Music の実測値でも `ScrollView` の内部しきい値でもない（仕様 4.2 章）。
    private static let decisionDistance: CGFloat = 10
    private static let horizontalRatio: CGFloat = 1.5

    private var origin: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // 2 本目以降は確定させない。成立前なら失敗、成立後なら取り消しで、どちらもシークしない。
        guard numberOfTouches == 1, let touch = touches.first else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        origin = touch.location(in: view)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let origin, let touch = touches.first else { return }
        switch state {
        case .possible:
            let movement = CGPoint(
                x: touch.location(in: view).x - origin.x,
                y: touch.location(in: view).y - origin.y
            )
            // 10 pt に届くまでは何も決めない。`.possible` のままなので本文のスクロールも妨げない。
            guard max(abs(movement.x), abs(movement.y)) >= Self.decisionDistance else { return }
            // 判定は一度だけ。横と言い切れない斜め・同値はスクロール側へ渡し、この接触ではもう戻らない。
            state = abs(movement.x) > abs(movement.y) * Self.horizontalRatio ? .began : .failed
        case .began, .changed:
            // 開始後は固定する。指が縦へ流れても、領域の外へ出ても同じ接触のまま続ける（仕様 4.2 章）。
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        // 10 pt に届かないまま離したタップはここで失敗させる。`.ended` にすると押した位置へ飛ぶ。
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        origin = nil
    }

    /// 外側の `ScrollView` にシークの失敗を待たせる。横シークが成立したあと指が縦へ流れても
    /// 本文へ渡らないようにするためで、依存を作るのはこの 1 方向だけ（仕様 4.2 章）。
    /// この認識器はシークバーの当たり判定にしか付いていないので、領域の限定は掛け直さない。
    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        guard let scrollView = other.view as? UIScrollView else { return false }
        return other === scrollView.panGestureRecognizer
    }
}

/// 操作帯の見た目と、歌詞を見せる下端を同じ補間値から作る（仕様 5.1 章 第 6 版）。
/// 通常の `@State` だけでは最終値しか渡らないため、この View 自身を補間対象にする。ただし
/// 内側 ScrollView の frame は最大高へ固定し、毎フレーム変えるのは外側の clip と当たり判定だけにする。
private struct ControlsTransition<Content: View>: View, Animatable {
    var progress: CGFloat
    let controlsInset: CGFloat
    let safeAreaInset: CGFloat
    @ViewBuilder let content: (CGFloat, CGFloat, CGFloat) -> Content

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let visibleProgress = min(max(progress, 0), 1)
        let hiddenProgress = 1 - visibleProgress
        content(
            visibleProgress,
            controlsInset * hiddenProgress,
            safeAreaInset * hiddenProgress
        )
    }
}

/// 前後送りの無効時の色を、様式の既定の減光ではなく指定で出すための器。既定の様式は無効なボタンを
/// 約 53 % で描くので白が RGB 163 になるが、参照の無効時は **129**（仕様 6.2.1 章）。
/// `makeBody` で色を決めれば減光は掛からず、`.disabled` 自体は残るので当たり判定と
/// 読み上げの「使用不可」は変わらない。
private struct TransportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color(white: 129.0 / 255.0))
            // `.plain` の押下時の反応だけは残す。
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// iPad のフルプレイヤーの寸法（仕様 6.2 章）。**原点は window の左上**で、y は 1366 × 1024 pt の
/// 画面で測った値。参照画像から測った絶対値をそのまま置く。iPhone 側の `PlayerLayout` のように高さの比率で帯を
/// 配らないのは、参照が高さに応じて帯を伸ばさず、カラムを固定したまま同じ位置に置いているため。
private enum PadPlayer {
    /// カラムの幅。window 幅からの式とは 1 機種の画像では区別できないので定数として扱う。
    static let columnWidth: CGFloat = 519
    static var mediaHeight: CGFloat { columnWidth }
    /// 本文を出すときのカラムの左端。67 + 519 + 67 = 653 で本文の面が始まる。
    static let columnLeft: CGFloat = 67
    static let panelLeft: CGFloat = 653
    /// 本文の面の右余白（1366 − 1314）。
    static let panelTrailing: CGFloat = 52
    /// メディア帯の上端。カラムの上下中央寄せと読むと 1.75 pt 残るので実測値を直に使う。
    static let mediaTop: CGFloat = 119
    /// 本文を出すときのアートワーク。519 pt の帯の中で上下左右 70 pt 均等になる。
    static let compactArtworkSide: CGFloat = 379
    /// 曲が無いとき（Not Playing）のアートワーク。参照の実測は 377.5 pt 角で、519 pt でも
    /// その 90 %（467 pt）でもない別の寸法（仕様 6.2 章）。帯の中心は 519 pt のときと同じ。
    static let emptyArtworkSide: CGFloat = 377.5
    /// 曲が無いときの記号の比。参照のインク高は 179.5 pt（四角の 0.475）で、`music.note` の
    /// インク高は指定サイズの 0.965 倍なので 179.5 ÷ 0.965 ÷ 377.5 ＝ 0.493（仕様 6.2.1 章）。
    static let emptyIconScale: CGFloat = 0.493
    /// 曲が無いときの四角の地に重ねる黒の不透明度。参照は四角の内と外を同じ y で比べると
    /// 比が 0.899〜0.900 一定＝**黒を約 10 % 重ねた面**で、`.quaternary` のような白の加算ではない
    /// （仕様 6.2.1 章）。黒の 10 % を敷くと地はちょうど 0.90 倍になる。
    static let emptyPlaceholderDarkening: CGFloat = 0.10
    /// 曲名・アーティストの枠の上端。実測は cap 上端 683 / 字面上端 707 で、ここはそこから
    /// 書体の ascender と cap height の差（.title2 で約 5.1 pt、.title3 で約 4.7 pt）だけ戻した値。
    /// **通常の文字サイズでの換算**なので、拡大時に参照と一致することは確かめていない。
    static let titleTop: CGFloat = 677.9
    static let artistTop: CGFloat = 702.3
    /// 曲名・アーティストに渡す幅。左端はカラムの端に揃える（実測の字面 68.5 とカラム 67.0 の差
    /// 1.5 pt は字形の side bearing なので内側の余白は 0）。右端は操作 2 つのぶんだけ空ける。
    static var textWidth: CGFloat { columnWidth - 80 }
    /// 曲名帯の右端の操作 2 つ。実測は 32 pt の丸が 2 個で、中心がカラム右端から 16 / 64 pt 内側
    /// （中心間 48）。44 pt のタップ枠でその中心に合わせると、枠は右へ 6 pt はみ出す。
    static let trailingActionSpacing: CGFloat = 48
    static var trailingActionsFrameWidth: CGFloat { columnWidth + rowHeight / 2 - 16 }
    /// シークバーの枠の上端。参照の帯は 746..753（高さ 7）で、こちらは 44 pt の枠の中央に
    /// 7 pt の帯を置くので、帯の上端に合わせるには枠を 18.5 pt 上げる。
    static let seekTop: CGFloat = 727.5
    /// トランスポートの枠の上端。参照の再生記号の字面の中心 y が 828.0、こちらは 64 pt 枠の中央に
    /// 字面の中心が来るので 796.0 で合う（撮り直して実測 825.5 だった 793.3 から 2.5 pt 下げた）。
    static let transportTop: CGFloat = 796.0
    static let transportHeight: CGFloat = 64
    /// 記号の中心間は**等間隔ではない**（仕様 6.2 章）。96.75 pt は前・再生・次の 3 つの間だけで、
    /// shuffle と repeat はそこから約 148.9 pt 外側にある。両端の 44 pt 枠はカラムの外へ 8 pt
    /// ずつ出て、行の全幅は 519 + 8 × 2 = 535 pt になる。
    static let transportInnerSpacing: CGFloat = 96.75
    static let transportOuterOffset: CGFloat = 245.75
    static var transportWidth: CGFloat { columnWidth + 16 }
    /// トランスポートの記号の指定サイズ。参照の字面（shuffle / repeat 18.5 × 15.0、前後送り
    /// 39.5 × 23.0、再生 30.0 × 40.0 pt）を、同じ記号をこちらで描いたときの字面と比べた比で
    /// iPhone の指定値を割り直した値。iPhone の 22 / 30 / 48 より一段小さい。
    static let sideGlyphSize: CGFloat = 15.4
    static let skipGlyphSize: CGFloat = 28.3
    static let playGlyphSize: CGFloat = 46.7
    static let volumeCenter: CGFloat = 894.5
    /// 下段の 44 pt 枠の上端。記号の中心 y は 4 画面すべて 987 pt で、下端 1009 と画面下端 1024 の
    /// 差が下余白 15 pt になる。
    static let bottomRowTop: CGFloat = 965
    static let rowHeight: CGFloat = 44
    /// 下段の記号の中心 x（仕様 6.2 章）。カラムが 423.5 → 67 pt へ寄っても 4 画面で動かない。
    static let lyricsGlyphCenter: CGFloat = 1216.8
    static let queueGlyphCenter: CGFloat = 1294.8
    static let routeGlyphCenter: CGFloat = 78.8
}

/// 4 章の帯の高さ。**アートワークの一辺を先に確保し**、比率はその残りの配り方として使う。
/// 以前は比率で帯を配ってからアートワークを `min(幅, 高さ)` で切っていたが、それだと高い端末ほど
/// 高さ側が先に効いて一辺が幅に届かない。Apple 実機は端末が低くても `画面幅 − 48` ちょうどなので、
/// 幅を基準に取り直す。曲名以下の縦位置を保つ旧規則は、Apple と合わないので意図的に破っている。
private struct PlayerLayout {
    let media: CGFloat
    let title: CGFloat
    let seek: CGFloat
    let transport: CGFloat
    let volume: CGFloat
    let bottom: CGFloat

    /// 下部の帯は高さを固定する。中身を上寄せにして、選択円の下に残る余白でこの値が効く（仕様 4 章）。
    static let bottomHeight: CGFloat = 55

    /// シーク以降の 4 帯の合計（仕様 5.1 章 第 4 版）。歌詞で操作帯を画面外へ逃がす距離に使う。
    /// この型は帯の**配分**を決めるものなので、退避の距離を `init` で確定させず、必要な側で足す。
    var controlsHeight: CGFloat { seek + transport + volume + bottom }

    init(height: CGFloat, artworkMedia: CGFloat, titleMinimum: CGFloat, seekMinimum: CGFloat) {
        let reclaimedTop = max(44, height * 0.07)
        var title = max(titleMinimum, height * 0.113)
        // `seek` と `bottom` は比率で伸ばさない（仕様 4 章の差し替え）。音量記号から下部の円までの距離は
        // 2 帯の合計で決まるので、比率で膨らむ帯を残しておくと目標の合計に届かない。
        // 拡大後の実寸のほうが大きいときだけそちらを採るので、文字が欠けることはない。
        let seekFloor = max(seekMinimum, 80)
        var seek = seekFloor
        // 低い画面でも再生ボタンの高さを下回らず、縦方向に欠けないようにする。
        var transport = max(64, height * 0.118)
        var volume = max(44, height * 0.08)
        var bottom = Self.bottomHeight
        // 旧上部領域をそのままメディアへ移す。帯を削ったぶんはここへ戻る。
        let mediaHeight = { (bands: CGFloat) in reclaimedTop + max(96, height - reclaimedTop - bands) }

        // 幅から決まる一辺に足りない分だけを、最小値を上回っている帯から借りる。
        // 借りる順番は余裕の大きい下から上へ。文字と操作の帯を最小値より削ってまで画像を広げはしない。
        var shortfall = artworkMedia - mediaHeight(title + seek + transport + volume + bottom)
        // 各帯は `max(最小値, 比率)` で作ってあるので、持ち出せるのはその差だけ。
        // `title` と `seek` の最小値は文字拡大後の実寸が渡ってくるので、拡大時も文字が欠けない。
        func borrow(from band: inout CGFloat, minimum: CGFloat) {
            let taken = min(max(0, band - minimum), max(0, shortfall))
            band -= taken
            shortfall -= taken
        }
        // 順番は変えない。ただし `bottom` と `seek` は下限が高さそのものなので、実際に貸せるのは
        // `volume` / `title` / `transport` の 3 つだけになる。下部と音量の距離を固定した帰結である。
        borrow(from: &bottom, minimum: Self.bottomHeight)
        borrow(from: &volume, minimum: 44)
        borrow(from: &title, minimum: titleMinimum)
        borrow(from: &transport, minimum: 64)
        borrow(from: &seek, minimum: seekFloor)

        self.title = title
        self.seek = seek
        self.transport = transport
        self.volume = volume
        self.bottom = bottom
        // 借りても届かないときは、従来どおり最後にアートワークのほうが縮む。
        media = mediaHeight(title + seek + transport + volume + bottom)
    }
}

/// 与えられた矩形を**下へ `extra` ぶんだけ**広げた形（仕様 5.1 章 第 4 版）。
/// 歌詞で操作帯を退避させている間、上部の切り抜きと当たり判定をこの形に揃えて、
/// 伸ばした本文が枠の下端で切られたり、そこだけ操作を受け付けなくなったりするのを防ぐ。
private struct BottomExtendedRect: Shape {
    var extra: CGFloat

    /// 帯の出し入れと高速反転の途中値で下端を切り抜く。補間できないと内側 ScrollView は
    /// 最大高のままなのに切り抜きだけが最終形へ飛び、文字が帯へ重なるか下端に空白が生じる。
    nonisolated var animatableData: CGFloat {
        get { extra }
        set { extra = newValue }
    }

    nonisolated func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + max(0, extra)))
    }
}

/// 上部の 5 つの子を、アートワーク状態と歌詞・キュー状態の配置の間に置くレイアウト（仕様 5.1 章）。
/// `progress` が 0 で大画像、1 で 72 pt の見出し。同じ子を保ったまま**置き場所と提示する大きさだけ**を
/// 補間するので、画像や文字が状態ごとに別の View へ差し替わらず、遷移の途中で二重に写らない。
/// 帯の配分を持つのは `PlayerLayout` 側で、ここは受け取った高さの中の配置だけを決める。
/// `HStack` / `VStack` の差し替えにしないのは、大画像状態が「画像の下に曲情報」、
/// 歌詞状態が「画像の横に曲情報」で、同じ子のまま両方を表せる組み合わせが無いため。
private struct PlayerTopLayout: Layout {
    /// 0 = アートワーク状態、1 = 歌詞・キュー状態。
    var progress: CGFloat
    /// アートワーク状態の一辺。帯の高さで縮めた後の値を受け取る。
    let bigArtworkSide: CGFloat
    /// 大画像の上端まで（仕様 4 章の 35 pt）。
    let artworkTop: CGFloat
    let mediaHeight: CGFloat
    let titleHeight: CGFloat
    /// アーティスト行を 1 行として数えるか。`Text("")` の実測幅で判定すると、
    /// 名前があっても幅が丸めで 0 になる状況に引きずられるので、呼び出し側の値で決める。
    let hasArtist: Bool
    /// 見出しと本文の間（仕様 5.1 章）。歌詞は 0、キューは `compactBottom`。
    /// `animatableData` に載せないので状態が変わった時点で切り替わるが、本文が見えているのは
    /// 歌詞・キューのときだけで、その 2 つの行き来では本文がクロスフェードして入れ替わる。
    let detailGap: CGFloat

    /// 歌詞・キュー時の見出しの寸法（仕様 5.1 章）。画像は 72 pt 角。
    static let compactArtworkSide: CGFloat = 72
    /// 大画像と違ってこちらは実測が 2.7 pt 大きかったので、共通の 35 ではなく 32 を使う。
    /// `artworkTop` を下げるとアートワーク状態の大画像の上端まで動いてしまい、そちらは一致済み。
    private static let compactTop: CGFloat = 32
    /// 見出しの下の余白。**歌詞では 0 を渡して使わない**ので、既定はキュー側の値と考える。
    static let compactBottom: CGFloat = 16
    /// 画像と曲情報の間、曲情報とお気に入りの間。
    private static let spacing: CGFloat = 12
    /// 外側の 24 pt より一段内側の 32 pt にするための差（仕様 4 章）。
    private static let sideInset: CGFloat = 8
    /// お気に入りとメニューの操作領域（仕様 4 章）。
    private static let actionSide: CGFloat = 44
    private static let actionSpacing: CGFloat = 4

    /// `progress` を補間対象にする。子の identity は変わらないので、動くのは配置だけになる。
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        CGSize(
            width: proposal.replacingUnspecifiedDimensions().width,
            height: mediaHeight + titleHeight
        )
    }

    /// 添字は `topArea` の並び順（本文・画像・曲名・アーティスト・お気に入り）。
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard subviews.count == 6 else {
            assertionFailure("`topArea` の子は 6 つ（本文・画像・曲名・アーティスト・お気に入り・メニュー）で固定")
            return
        }
        let width = bounds.width

        // 曲情報とお気に入りは同じ行に載るので、行の中心を共有する。
        // 歌詞・キュー状態のお気に入りは行の右端に残す指定（仕様 5.1 章）なので、右の内側余白は足さない。
        let infoLeading = lerp(Self.sideInset, Self.sideInset + Self.compactArtworkSide + Self.spacing)
        let actionsTrailing = lerp(Self.sideInset, 0)
        let actionsWidth = Self.actionSide * 2 + Self.actionSpacing
        let infoWidth = max(0, width - infoLeading - actionsTrailing - actionsWidth - Self.spacing)
        let infoProposal = ProposedViewSize(width: infoWidth, height: nil)

        // 2 行の縦位置は、**行間だけが違う同じ組み方**を両状態ぶん作って補間する。
        // 高さは今のフォントのものしか測れないので、両端の計算に同じ高さを使う。
        // 落ち着いた状態ではそのフォントの高さで測れているので誤差は出ず、
        // 途中の数 pt のずれは中央合わせで半分になる。
        let titleSize = subviews[2].sizeThatFits(infoProposal)
        let artistSize = subviews[3].sizeThatFits(infoProposal)
        let artistHeight = hasArtist ? artistSize.height : 0
        let bigGap: CGFloat = hasArtist ? 4 : 0
        let compactGap: CGFloat = hasArtist ? 2 : 0

        // 歌詞・キュー状態の見出し行の高さは、**文字から決める**。72 pt に固定すると
        // 文字を大きくしたときに 2 行が行からあふれ、下の本文に重なる。
        // 既定の文字サイズでは 72 pt が最大になるので、これまでの配置と同じ値になる。
        let compactHeader = max(
            Self.compactArtworkSide,
            titleSize.height + compactGap + artistHeight,
            Self.actionSide
        )

        // 本文は歌詞・キュー状態の見出しの下に固定する。ここを `progress` で動かすと、
        // 出入りのフェードと縦移動が重なって文字が流れて見える。
        let detailTop = Self.compactTop + compactHeader + detailGap
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + detailTop),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: max(0, mediaHeight + titleHeight - detailTop))
        )

        let side = lerp(bigArtworkSide, Self.compactArtworkSide)
        subviews[1].place(
            at: CGPoint(
                x: bounds.minX + lerp((width - bigArtworkSide) / 2, Self.sideInset),
                // 行が文字で伸びたときは、72 pt の画像を行の中で縦中央に置く。
                y: bounds.minY
                    + lerp(artworkTop, Self.compactTop + (compactHeader - Self.compactArtworkSide) / 2)
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: side, height: side)
        )

        let rowCenter = lerp(mediaHeight + titleHeight / 2, Self.compactTop + compactHeader / 2)
        let bigBlockTop = rowCenter - (titleSize.height + bigGap + artistHeight) / 2
        let compactBlockTop = rowCenter - (titleSize.height + compactGap + artistHeight) / 2
        let titleCenter = lerp(bigBlockTop, compactBlockTop) + titleSize.height / 2
        let artistCenter =
            lerp(bigBlockTop + bigGap, compactBlockTop + compactGap) + titleSize.height + artistHeight / 2

        subviews[2].place(
            at: CGPoint(x: bounds.minX + infoLeading, y: bounds.minY + titleCenter),
            anchor: .leading,
            proposal: infoProposal
        )
        subviews[3].place(
            at: CGPoint(x: bounds.minX + infoLeading, y: bounds.minY + artistCenter),
            anchor: .leading,
            proposal: infoProposal
        )
        let menuCenterX = bounds.maxX - actionsTrailing - Self.actionSide / 2
        let favoriteCenterX = menuCenterX - Self.actionSide - Self.actionSpacing
        subviews[4].place(
            at: CGPoint(x: favoriteCenterX, y: bounds.minY + rowCenter),
            anchor: .center,
            proposal: ProposedViewSize(width: Self.actionSide, height: Self.actionSide)
        )
        subviews[5].place(
            at: CGPoint(x: menuCenterX, y: bounds.minY + rowCenter),
            anchor: .center,
            proposal: ProposedViewSize(width: Self.actionSide, height: Self.actionSide)
        )
    }

    private func lerp(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}

/// スライダーを枠の上下中央へ置き直すためだけの `MPVolumeView`。
/// 素の `MPVolumeView` は出力先ボタンが同居していた頃の配置を引きずっていて、
/// 与えた高さの中でスライダーを上寄りに置く。44 pt の枠に入れると左右の記号と中心がずれる。
private final class CenteredVolumeView: MPVolumeView {
    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        let rect = super.volumeSliderRect(forBounds: bounds)
        // 大きさと x は Apple の計算のまま使う。つまみを消して 6 pt の線へ差し替えた分の寸法も
        // あちらが持っているので、こちらで高さを決め直すとその調整まで失う。動かすのは y だけ。
        return CGRect(x: rect.minX, y: bounds.midY - rect.height / 2, width: rect.width, height: rect.height)
    }
}

private struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> CenteredVolumeView {
        // iOS 13 以降の MPVolumeView はスライダーだけで、出力先は下部の AVRoutePickerView が担う。
        // `showsRouteButton` は同時に非推奨となり既定で false なので、明示的に触らない。
        let view = CenteredVolumeView()
        view.isHidden = false
        view.alpha = 1
        configureSlider(in: view)
        return view
    }

    func updateUIView(_ uiView: CenteredVolumeView, context: Context) {
        uiView.isHidden = false
        uiView.alpha = 1
        configureSlider(in: uiView)
    }

    private func configureSlider(in view: MPVolumeView) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // シークバーと同じ 7 pt の線へ揃え、音量だけ UIKit 標準の細線に戻らないよう画像で固定する。
        slider.setMinimumTrackImage(trackImage(color: .label), for: .normal)
        slider.setMaximumTrackImage(trackImage(color: .tertiaryLabel), for: .normal)
        slider.setThumbImage(UIImage(), for: .normal)
        slider.setThumbImage(UIImage(), for: .highlighted)
    }

    private func trackImage(color: UIColor) -> UIImage {
        // 太さ 7 pt に対して幅を 1 pt 広く取る。半径 3.5 の丸めが左右それぞれ 3.5 pt を使い切るので、
        // 幅 8 なら中央の 1 pt がちょうど直線部になり、そこだけが伸縮域になる。
        // キャップを半径より小さくして中央を作る手もあるが、伸縮域に弧が入って横へ引き伸ばされる。
        // `MPVolumeView` は Simulator に描かれず目視で確かめられないので、弧を入れない形を選ぶ。
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 7))
        return renderer.image { context in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 8, height: 7), cornerRadius: 3.5).fill()
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 3.5, left: 3.5, bottom: 3.5, right: 3.5))
    }
}

private struct AudioRouteView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#Preview {
    NowPlayingView(isScrubbing: .constant(false), close: {})
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
}
