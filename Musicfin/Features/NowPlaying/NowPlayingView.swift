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
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title2) private var minimumTitleHeight = 76.0
    @ScaledMetric(relativeTo: .caption) private var minimumSeekHeight = 64.0

    /// シークが成立している間だけシステムの対話的な終了を止める（仕様 4.1 章）。
    /// 抑止を掛けるのは sheet を出している `RootView` 側なので、この状態だけ外に持たせて共有する。
    /// 再生側の状態ではないので `PlaybackEngine` には置かない。
    @Binding var isScrubbing: Bool

    @State private var mode: ContentMode = .artwork
    @State private var scrubTime = 0.0
    /// キュー内の `MediaItem` はお気に入りの変更を追わないので、サーバーの確定値をここに持つ。
    @State private var favoriteTrack: MediaItem?
    @State private var isUpdatingFavorite = false
    /// アートワークと曲情報を状態間で繋ぐための名前空間。差し替えではなく位置で動かす（仕様 5.1 章）。
    @Namespace private var transition

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
    var body: some View {
        ArtworkBackdrop(item: player.currentItem, band: .player, artworkSize: Self.paletteArtworkSize) { palette in
            content(palette: palette)
        }
    }

    private func content(palette: ArtworkPalette) -> some View {
        GeometryReader { geometry in
            // アートワークは左右 24 pt を引いた幅いっぱいが基準（Apple 実機は `画面幅 − 48` ちょうど）。
            let artworkSide = geometry.size.width - 48
            let layout = PlayerLayout(
                height: geometry.size.height,
                artworkMedia: Self.mediaHeight(forArtworkSide: artworkSide),
                titleMinimum: minimumTitleHeight,
                seekMinimum: minimumSeekHeight
            )
            // 歌詞・キューは自前でスクロールするので、外側の `ScrollView` ごと構成を切り替える（仕様 5.1 章）。
            if mode == .artwork {
                ScrollView {
                    VStack(spacing: 0) {
                        artwork(width: artworkSide, height: layout.media)
                            .frame(height: layout.media)
                            .clipped()
                        titleRow.frame(height: layout.title)
                        seekControls.frame(height: layout.seek)
                        transport.frame(height: layout.transport)
                        // 音量は帯の下端へ、下部の記号は帯の上端へ寄せる。この 2 つを中央に置いたままだと
                        // 音量記号から選択円までが (volume + bottom) / 2 で決まってしまい、
                        // 最小値だけで目標を 15 pt 超えるので比率をいくら下げても届かない（仕様 4 章）。
                        // 寄せるのは 44 pt の操作行ごとで、記号だけを動かすのではない。
                        volumeRow.frame(height: layout.volume, alignment: .bottom)
                        bottomControls(palette: palette).frame(height: layout.bottom, alignment: .top)
                    }
                    .padding(.horizontal, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            } else {
                VStack(spacing: 0) {
                    // 本文が占めるのはメディア領域と曲名行を合わせた上部だけ（仕様 5.1 章）。
                    // 高さを固定して残り 4 つの帯を押し下げさせないので、あふれたぶんは本文側が自分でスクロールする。
                    VStack(spacing: 0) {
                        compactHeader
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(height: layout.media + layout.title)
                    .clipped()
                    // 以下 4 つはアートワーク状態と同じ順・同じ高さ・同じ縦揃えで並べる。
                    // 帯も揃えも同一なので、3 状態で記号の縦位置が一致する（仕様 5.1 章）。
                    seekControls.frame(height: layout.seek)
                    transport.frame(height: layout.transport)
                    volumeRow.frame(height: layout.volume, alignment: .bottom)
                    bottomControls(palette: palette).frame(height: layout.bottom, alignment: .top)
                }
                .padding(.horizontal, 24)
            }
        }
        // iPad では 560pt を目安にした中央の sheet にする（6 章）。
        .frame(idealWidth: 560, maxWidth: .infinity, idealHeight: 800)
        .overlay(alignment: .top) { grabber }
        // 地が常に暗い帯になったので、明るい外観の端末でも文字と記号は白のままにする（仕様 1.2 章）。
        // 個々の `.primary` / `.secondary` を白に置き換えて回らないのは、選択中の記号が地の色へ
        // 反転する `modeButton` のように、白の指定だけでは足りない組みがあるため。
        .environment(\.colorScheme, .dark)
        // sheet はタブの tint を引き継がないので、ここで改めてピンクに揃える。
        .tint(.pink)
        // 閉じるボタンは置かない方針（仕様 4 章）なので、下スワイプの届かない VoiceOver へ
        // エスケープ操作だけは自前で用意する（仕様 4.1 章）。
        .accessibilityAction(.escape) { dismiss() }
        .task(id: player.currentItem?.id) {
            isScrubbing = false
            favoriteTrack = player.currentItem
            guard let id = player.currentItem?.id, let client = auth.client else { return }
            if let item = try? await client.fetchItem(id: id), !Task.isCancelled {
                favoriteTrack = item
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
    private var grabber: some View {
        Capsule()
            .fill(.white.opacity(0.42))
            .frame(width: 60, height: 5)
            // 10 pt だと上端が 72 pt に出て、仕様 4 章が記録する 67 pt より 5 pt 下がったので引いた。
            // なぜ 5 pt ずれるのかは確かめていない。この値は撮り直して測るまで確定ではない。
            .padding(.top, 5)
            // 触れない・読み上げない。閉じる経路は `accessibilityAction(.escape)` が持つ。
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - アートワーク / 歌詞 / キュー

    /// アートワーク状態の大きな正方形。基準は幅いっぱいで、帯の高さが足りないときだけ縮める（仕様 4 章）。
    /// 帯のほうは `PlayerLayout` が一辺を先に確保しに行くので、通常は `width` で決まる。
    private func artwork(width: CGFloat, height: CGFloat) -> some View {
        let available = height - Self.artworkTopInset - Self.artworkBottomInset
        return artworkImage(size: max(1, min(width, available)), cornerRadius: 20)
            // 停止中は 90% に縮めて「止まっている」ことを形で示す。視差効果を減らす設定なら固定。
            .scaleEffect(reduceMotion || player.isPlaying ? 1 : 0.9)
            .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: player.isPlaying)
            // 影は無彩色に替えるのではなく付けない。画像そのものを見せる（仕様 1.1 章）。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, Self.artworkTopInset)
    }

    private func artworkImage(size: CGFloat, cornerRadius: CGFloat) -> some View {
        ArtworkView(item: player.currentItem, size: size, cornerRadius: cornerRadius)
            .matchedGeometryEffect(id: "artwork", in: transition)
    }

    /// 歌詞・キューの本体。アートワーク状態では出さない。
    @ViewBuilder
    private var detail: some View {
        switch mode {
        case .artwork:
            EmptyView()
        case .lyrics:
            if let track = player.currentItem {
                LyricsView(track: track)
                    .id(track.id)
            }
        case .queue:
            QueueView()
        }
    }

    // MARK: - 曲情報

    /// 歌詞・キュー時の上部。72 pt のアートワークの右に曲名・アーティストを 2 行で並べ、
    /// お気に入りは同じ行の右端に残す（仕様 5.1 章）。
    private var compactHeader: some View {
        HStack(spacing: 12) {
            artworkImage(size: 72, cornerRadius: 8)
            songInfo(compact: true)
            favoriteButton
        }
        // 画像と曲名だけを外側の 24 pt より一段内側の 32 pt へ入れる。
        // お気に入りは行の右端に残す指定（仕様 5.1 章）なので、右側には足さない。
        .padding(.leading, 8)
        // 大画像と違ってこちらは実測が 2.7 pt 大きかったので、共通の 35 ではなく 32 を使う。
        // `artworkTopInset` を下げるとアートワーク状態の大画像の上端まで動いてしまい、そちらは一致済み。
        .padding(.top, 32)
        .padding(.bottom, 16)
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            songInfo(compact: false)
            favoriteButton
        }
        // アートワークの 24 pt より一段内側の左右 32 pt へ入れる（仕様 4 章）。
        .padding(.horizontal, 8)
    }

    /// 曲名とアーティスト。歌詞・キューでは 72 pt のアートワーク横へ収まる大きさへ落とす。
    /// 曲情報はアートワークと同じく位置のアニメーションで前後の状態を繋ぐ（仕様 5.1 章）ので、
    /// `matchedGeometryEffect` は `.position` だけに絞る。既定では大きさも対応付けてしまい、
    /// 全幅のアートワーク状態と、アートワーク・お気に入りを除いた狭い歌詞状態とが寸法を取り合って、
    /// 文字の塊ごと横に伸び縮みして飛んで見えるため。
    /// 付ける先を外側ではなく各 `Text` にするのも同じ理由で、幅を決める `frame` の内側であれば
    /// 幅・揃え・改行はそれぞれの状態のレイアウトに委ねたまま、位置だけが連続する。
    private func songInfo(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            Text(player.currentItem?.displayName ?? String(localized: "再生していません"))
                .font(compact ? .headline : .title2.bold())
                .lineLimit(compact ? 1 : 2)
                .matchedGeometryEffect(id: "songTitle", in: transition, properties: .position, anchor: .center)
            if let artist = player.currentItem?.displayArtist {
                // アーティスト名はアクセント色にしない（仕様 4 章）。曲名に近い大きさの secondary。
                Text(artist)
                    .font(compact ? .subheadline : .title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .matchedGeometryEffect(id: "songArtist", in: transition, properties: .position, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var favoriteButton: some View {
        Button {
            Task { await toggleFavorite() }
        } label: {
            // ブラウズ画面と同じくお気に入りはハートで表す。
            Image(systemName: favoriteTrack?.isFavorite == true ? "heart.fill" : "heart")
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
        .matchedGeometryEffect(id: "favorite", in: transition)
    }

    // MARK: - シーク

    private var displayedTime: TimeInterval { isScrubbing ? scrubTime : player.currentTime }

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
                    player.seek(to: value)
                },
                // システムに取り消されたら、掴んだ値は捨てて現在の再生位置の表示へ戻す（仕様 4.2 章）。
                onCancelled: { isScrubbing = false },
                adjust: { offset in player.seek(to: player.currentTime + offset) }
            )
            HStack {
                Text(displayedTime.timeLabel)
                Spacer()
                Text(max(0, player.duration - displayedTime).remainingLabel)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
        // シークバーも曲名と同じ左右 32 pt に揃える（仕様 4 章）。
        .padding(.horizontal, 8)
    }

    // MARK: - 再生操作

    private var transport: some View {
        // 記号の輪郭の中心どうしが Apple 実機で 106.8 pt。字形に依らない量として測れたのでそれに合わせる。
        // 以前の 61 は端末幅 430 pt を仮定した概算で、実測ではこの間隔が 9.7 pt 広かった。
        HStack(spacing: 51) {
            Button {
                player.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30, weight: .semibold))
                    // 塗りのない記号なので、当たり判定の 44 pt を形で明示する。
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前の曲")

            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 48, weight: .semibold))
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

            Button {
                player.playNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasNext)
            .accessibilityLabel("次の曲")
        }
        .disabled(player.currentItem == nil)
        .frame(maxWidth: .infinity)
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
        .font(.caption)
        .foregroundStyle(.secondary)
        // 曲名やシークと同じ左右 32 pt へ揃える（仕様 5 章）。外側の 24 pt との差を足す。
        .padding(.horizontal, 8)
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
            withAnimation(.snappy) { mode = isSelected ? .artwork : target }
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
private final class SeekGestureRecognizer: UIGestureRecognizer {
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
    NowPlayingView(isScrubbing: .constant(false))
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
}
