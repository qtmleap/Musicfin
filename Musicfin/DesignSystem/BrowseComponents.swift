import SwiftUI
import UIKit

// ブラウズ画面で共有する部品。Apple Music 実機に合わせ、装飾を足さず素材そのものを見せる。

/// 各画面の背景。アートワークの色を邪魔しないよう、Apple Music と同じく無彩色の地にする。
/// `List` に重ねるときは `.scrollContentBackground(.hidden)` を併用する。
struct AppBackdrop: View {
    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
    }
}

/// アルバム／プレイリストのカード。影や大きな角丸は付けず、アートワーク自体を主役にする。
struct AlbumCard: View {
    let item: MediaItem
    var size: CGFloat = 160
    /// 省略時はアーティスト名。アーティスト詳細のように文脈で自明なときは別の文言（年など）に差し替える。
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Apple 実機の角の輪郭は一辺に比例せず、ライブラリの一覧の行は 5 pt、検索結果の行だけが 4 pt、
            // グリッドのカードは 8 pt で分かれる（仕様 1.1 章）。
            ArtworkView(item: item, size: size, cornerRadius: 8)

            // Apple 実機は作品名とアーティスト名を同じ大きさで置き、色の濃淡だけで主従を付ける。
            // 左端も画像に揃うので、文字側に横余白は入れない。
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.footnote)
                    .lineLimit(1)
                Text(subtitle ?? item.albumArtist ?? item.displayArtist ?? item.albumSubtitle)
                    .font(.footnote)
                    // 階層スタイルの `.secondary` は現在の前景スタイルからの導出なので、`List` の中に
                    // 置いたときだけ白の半分になり、`ScrollView` に置いた同じカードと色が食い違う。
                    // 置き場所で副題の色が変わる理由は無いので、ラベル色を直に指して固定する。
                    // Apple 実機のライブラリは下部 UI に隠れて測れない。実測ではなく、ホーム・
                    // アルバム一覧に既に出ている側へ揃える一貫性の判断（仕様 1.1 章）。
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1)
            }
        }
        .frame(width: size)
    }
}

/// 曲一覧の 1 行。再生中の曲は既定では tint（ピンク）で示す。
/// アートワーク由来の地に載る画面だけは、地に埋もれないよう `currentStyle` で色を差し替える。
struct TrackRow: View {
    /// トラック番号の桁幅。曲名（＝アルバム詳細の区切り線）の左端を決めるので外からも参照する。
    /// 揃え位置の計算は `alignmentGuide` の Sendable なクロージャからも引くので分離する。
    nonisolated static let numberColumnWidth: CGFloat = 22
    /// 番号から曲名までの間隔。左端 20 pt と合わせて曲名の左端が 51 pt になる（Apple 実機の実測）。
    nonisolated static let numberTitleSpacing: CGFloat = 9
    /// 画像から曲名までの間隔。罫線の左端も同じ基準で引くので外からも参照する。
    nonisolated static let artworkTitleSpacing: CGFloat = 12
    /// 曲行の画像の角丸。ライブラリの一覧の行は 5 pt（仕様 1.1 章）。一辺からは計算できず、
    /// Apple 実機の輪郭を測って決まる値。再生中に重ねる幕も同じ形で切るので定数にまとめる。
    private static let artworkCornerRadius: CGFloat = 5

    /// 番号列の実幅。文字拡大に合わせて 22 pt から伸びる。
    /// 罫線の開始位置も同じ基準（`numberColumnWidth` を `.body` で拡大）で決めれば、拡大時もずれない。
    @ScaledMetric(relativeTo: .body) private var numberWidth: CGFloat = TrackRow.numberColumnWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let track: MediaItem
    /// アルバム内ではトラック番号を、横断的な一覧ではアートワークを出す。
    var showsArtwork = false
    /// ライブラリ配下の一覧は 48 pt。ホームのお気に入り 3 段組だけは仕様 2 章の 44 pt を保つ。
    var artworkSize: CGFloat = 44
    /// この行が今の曲か。色とイコライザの有無を決める。
    var isCurrent = false
    /// 再生が進んでいるか。イコライザを動かすかどうかだけに効き、行の見た目は `isCurrent` が決める。
    var isPlaying = false
    /// 再生中の行の曲名と棒の色。無彩色の地に載る画面（ホーム・ライブラリ・キュー）は tint のままでよいが、
    /// アートワーク由来の地では固定色が地に埋もれるので、呼び出し側から前景色を渡してもらう（仕様 1.2 章）。
    var currentStyle: AnyShapeStyle = AnyShapeStyle(.tint)
    /// 画像付きの行で再生中の目印を出すときに、画像へ敷く幕の色。地の色を渡す。
    /// `nil` の間は画像に何も重ねない。曲名の色だけで再生中が分かる画面まで見た目を変えないため。
    var currentArtworkScrim: Color?

    var body: some View {
        // アートワークの行は 12 pt のままにし、番号の行だけ Apple 実機の 9 pt に詰める。
        HStack(spacing: showsArtwork ? Self.artworkTitleSpacing : Self.numberTitleSpacing) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayName)
                    .font(.body)
                    .foregroundStyle(isCurrent ? currentStyle : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if showsArtwork, let artist = track.displayArtist {
                    Text(artist)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
            // 行末は「…」だけで終える。再生時間もお気に入りの印も出さない（仕様 1.1 章）。
            // お気に入りかどうかは「…」の中の「お気に入りから削除／追加」で分かる。
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var leading: some View {
        if showsArtwork {
            // 検索結果だけが 4 pt で、グリッドのカードは 8 pt（仕様 1.1 章）。一辺からは計算できない。
            ArtworkView(item: track, size: artworkSize, cornerRadius: Self.artworkCornerRadius)
                .overlay { currentArtworkMarker }
        } else if isCurrent {
            // 今の曲は番号を伏せて、上下に動く 3 本の棒を出す。止まっているときは動かさない。
            PlayingEqualizer(
                width: numberWidth,
                isAnimating: isPlaying && !reduceMotion,
                style: currentStyle
            )
        } else {
            // 番号は列の中央に置く。3 桁や文字拡大では切らずに列ごと広げる。
            Text(track.indexNumber.map(String.init) ?? "–")
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(minWidth: numberWidth, alignment: .center)
        }
    }

    /// 画像付きの行の再生中の目印。番号列が無いぶん棒の置き場が無いので、画像の上に重ねる。
    /// 幕を敷くのは、棒の色が地の前景色（白か黒）で決まるのに対し、画像の明暗は曲ごとに違うため。
    /// 地の色で覆えば、行の文字と同じ「地の上に前景色」という関係のまま棒を読ませられる。
    /// 画像がどの曲かも残したいので覆い切らず、棒が読める下限として 0.6 を採る。
    /// Apple 実機のプレイリストにこの表示は無く、実測ではなくこちらの決定（仕様 8 章）。
    @ViewBuilder
    private var currentArtworkMarker: some View {
        if isCurrent, let currentArtworkScrim {
            ZStack {
                currentArtworkScrim.opacity(0.6)
                PlayingEqualizer(
                    width: artworkSize,
                    isAnimating: isPlaying && !reduceMotion,
                    style: currentStyle
                )
            }
            .clipShape(.rect(cornerRadius: Self.artworkCornerRadius))
        }
    }
}

/// 今の曲の行に出す 3 本の棒。下端を揃えて上へ伸び、棒ごとに周期をずらす。
/// 棒の太さ・間隔・振れ幅・周期は、参照にしている Apple 実機の静止画からは動きを測れないので、
/// こちらで決めた値。番号列と同じ幅に収め、罫線の左端が動かないようにする。
private struct PlayingEqualizer: View {
    /// 3 本を同じ周期で振ると一体の塊に見えるので、互いに割り切れない長さをばらして与える。
    private static let periods: [Double] = [0.62, 0.47, 0.75]
    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2.5
    private static let tallest: CGFloat = 13
    private static let shortest: CGFloat = 4

    /// 置き場の実幅。文字拡大で番号列が伸びても棒は太らせず、中央に置いたままにする。
    /// 画像へ重ねるときは画像の一辺を受け取り、同じく中央に置く。
    let width: CGFloat
    let isAnimating: Bool
    /// 棒の色。曲名と同じ色で描かないと、同じ行の中で再生中の印だけ別の配色になる。
    let style: AnyShapeStyle

    var body: some View {
        HStack(alignment: .bottom, spacing: Self.barSpacing) {
            ForEach(Array(Self.periods.enumerated()), id: \.offset) { _, period in
                bar(period: period)
            }
        }
        .frame(width: width, height: Self.tallest)
        .foregroundStyle(style)
    }

    /// 止めるときは `PhaseAnimator` ごと外す。繰り返しのアニメーションを状態の切り替えで駆動すると、
    /// 一時停止で値が片側に残ったまま戻らず、再開しても動き出さないため。
    @ViewBuilder
    private func bar(period: Double) -> some View {
        if isAnimating {
            PhaseAnimator([Self.shortest, Self.tallest]) { height in
                Capsule().frame(width: Self.barWidth, height: height)
            } animation: { _ in
                .easeInOut(duration: period)
            }
        } else {
            // 止まっていても棒は消さない。番号ではなく「この行が今の曲」であることの印だから。
            Capsule().frame(width: Self.barWidth, height: Self.shortest)
        }
    }
}

/// アーティスト一覧の 1 行。Apple Music と同じく円形のアートワークと名前だけで構成する。
struct ArtistRow: View {
    let artist: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: artist, size: 48, cornerRadius: 24)
            Text(artist.displayName)
                .font(.body)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(.rect)
    }
}

/// アルバム／プレイリストなど「入れ物」の 1 行。Apple Music に合わせて画像を大きめに取る。
struct ContainerRow: View {
    let item: MediaItem
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            // 一辺は 64 pt だが、ライブラリの一覧の行なので曲一覧と同じ 5 pt（仕様 1.1 章）。
            ArtworkView(item: item, size: 64, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .lineLimit(1)
                // 副題は作品名より一段だけ小さくする。Apple 実機は 17 pt に対して 15 pt。
                Text(subtitle ?? item.albumArtist ?? item.displayArtist ?? item.albumSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }
}

/// 行末の「…」メニュー。中身が空のときは余白も作らない。
struct RowMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if Content.self == EmptyView.self {
            EmptyView()
        } else {
            Menu {
                content
            } label: {
                // Apple 実機の「…」は幅 15 pt ほど。tint にも secondary にも寄せず、地に対する前景色で描く。
                // `Color.primary` は固定のラベル色で、アートワーク由来の明るい地の上でも白のまま残る。
                // 階層のほうの `.primary` なら親の `foregroundStyle` を不透明度 100% で継ぐ（仕様 1.2 章）。
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    // 当たり判定は 44×44 pt を確保する。行に返す幅は従来の 32 pt のままにして、
                    // 記号の見える位置を動かさないよう、はみ出す 6 pt ずつを負の余白で相殺する。
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .padding(.horizontal, -6)
            }
            .accessibilityLabel("操作")
            .buttonStyle(.plain)
        }
    }
}

/// 検索の入力前に並べる分類タイル。Apple Music の編集画像は持てないので、色面と名前で見分ける。
struct BrowseTile: View {
    let title: String
    let index: Int
    var height: CGFloat = 96

    private static let palette: [Color] = [
        .pink, .purple, .indigo, .blue, .teal, .green, .orange, .red,
    ]

    var body: some View {
        // `hashValue` は起動ごとに変わり色が安定しないので、一覧内の位置から色を決める。
        let color = Self.palette[index % Self.palette.count]
        return Text(title)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(12)
            // アクセシビリティサイズの 2 行が入るよう、96 pt は下限として扱い内容の高さを親へ返す。
            .frame(minHeight: height)
            // 地は単色。Apple 実機のタイルは縦にも横にも階調を持たない（仕様 1.1 章）。
            // 14 pt は Apple 実機の角の後退量に合わせた値。§9 の検索結果の小画像 4 pt とは別物なので、
            // 片方に合わせて動かさない。
            .background(color, in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
    }
}

/// 検索タイルの列数と高さ。アルバムグリッドと同じく端末名ではなく幅で決める。
struct BrowseTileMetrics {
    let columns: Int
    let height: CGFloat

    init(width: CGFloat) {
        // 左右 20 pt・間隔 12 pt の 2 列で、393 pt 幅なら 1 枚 170×96 pt（Apple 実機の実測）。
        columns = width < 360 ? 1 : 2
        height = 96
    }

    var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
    }
}

/// 曲一覧の先頭に置く再生・シャッフル。Apple Music と同じく横並びの 2 ボタンにする。
struct TrackListActions: View {
    let play: () -> Void
    let shuffle: () -> Void
    var height: CGFloat = 48
    var listInsets: CGFloat? = 20

    var body: some View {
        // 左右 20 pt・間隔 16 pt なので、393 pt 幅なら 1 つ 168.5 pt。Apple 実機の実測に合う。
        HStack(spacing: 16) {
            Button(action: play) { capsule("再生", systemImage: "play.fill") }
            Button(action: shuffle) { capsule("シャッフル", systemImage: "shuffle") }
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .listRowInsets(
            EdgeInsets(top: 8, leading: listInsets ?? 0, bottom: 12, trailing: listInsets ?? 0)
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// `Label` を横幅いっぱいの枠に置くと記号と文字が 18 pt ほど離れるので、
    /// Apple 実機の実測どおり 6 pt で並べ直す。
    private func capsule(_ title: LocalizedStringResource, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .frame(maxWidth: .infinity, minHeight: height)
        .background(Color(.secondarySystemBackground), in: .capsule)
    }
}

/// ホーム右上のアカウント導線。Jellyfin にユーザー画像の API がないので、頭文字か人物グリフで代用する。
struct AccountAvatar: View {
    let name: String?
    var size: CGFloat = 30

    private var initial: String? {
        guard let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        return String(first).uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(.quaternary)
            if let initial {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.primary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// ライブラリのメニュー行に付けるアイコン。Apple Music と同じく tint 色のグリフだけで示す。
struct MenuIcon: View {
    let systemImage: String

    var body: some View {
        // Apple 実機のグリフは 22〜24 pt 幅。枠を 24 pt に取ると行の文字が左端 61 pt に揃う。
        Image(systemName: systemImage)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(.tint)
            .frame(width: 24, alignment: .leading)
    }
}

/// 見出しと「すべて表示」を備えた横スクロールのセクション。
/// Apple Music と同じく、見出し自体を送り先へのリンクにして余計な装飾を足さない。
struct CarouselSection<Content: View, Destination: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder var destination: Destination
    @ViewBuilder var content: Content

    /// 同じ画面のグリッドや大見出しと左端をそろえる。iPad の detail だけ 34.5 pt（仕様 6 章）。
    private var horizontalMargin: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 34.5 : 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                NavigationLink {
                    destination
                } label: {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.title2.bold())
                            .foregroundStyle(Color.primary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(title)をすべて表示"))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, horizontalMargin)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    content
                }
                // 同じ画面のグリッドと同じ余白にして、見出しとカードの左端も揃える。
                .padding(.horizontal, horizontalMargin)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

/// ホームとアルバム一覧で同じ列幅を使い、ウインドウのリサイズ時にも列を揃える。
/// 端末名ではなく利用可能幅で列数を決める（`docs/ui-spec.md` 6 章）。
struct AlbumGridMetrics {
    /// 列間（仕様 2 章）。列数の判定と実際の割り付けで同じ値を使わないと、選んだ列数と描く幅がずれる。
    private static let columnSpacing: CGFloat = 12
    /// 段間（仕様 2 章）。Apple 実機は画像上端から次段の画像上端までのうち画像以外が縦に 60.3 pt で、
    /// そのうち画像→文字と段間の内訳までは切り分けられていない。文字まわりは横送りでも使う寸法なので、
    /// 影響がこのグリッドだけで閉じる段間へ差を寄せている。列間と同じく、使う側で書き分けない。
    static let rowSpacing: CGFloat = 19
    /// 目安の帯 180〜220 pt の中心。帯の端ではなくここからの距離で列数を選ぶ（仕様 6 章）。
    private static let targetImageWidth: CGFloat = 200

    let columns: Int
    let size: CGFloat

    /// `horizontalMargin` は呼び出し側がグリッドに与える左右余白。iPhone の 20 pt が既定で、
    /// iPad の detail は 34.5 pt を渡す（仕様 6 章）。ここへ渡し忘れると列幅が余白ぶんだけはみ出す。
    init(width: CGFloat, horizontalMargin: CGFloat = 20) {
        // 左右余白ぶんを引いた残りに列を割る（仕様 2 章）。2 列なら画像幅は `(残り − 12) / 2` になる。
        let available = max(1, width - horizontalMargin * 2)
        // 画像幅 1 列あたり。列数を増やすほど単調に縮む。
        let imageWidth = { (count: Int) in
            (available - CGFloat(count - 1) * Self.columnSpacing) / CGFloat(count)
        }
        if width < 360 {
            columns = 1
        } else if width < 600 {
            columns = 2
        } else {
            // 180〜220 pt のどの列数でも帯に入らない幅があるので、帯に入る最小でも最大でもなく、
            // 中心 200 pt にもっとも近い画像幅になる列数を選ぶ（仕様 6 章）。
            // 単調に縮むので、200 pt を保てる最大の列数と、その 1 つ先だけ比べれば足りる。
            var fitting = 3
            while imageWidth(fitting + 1) >= Self.targetImageWidth { fitting += 1 }
            let overshoot = abs(imageWidth(fitting) - Self.targetImageWidth)
            let undershoot = abs(imageWidth(fitting + 1) - Self.targetImageWidth)
            columns = overshoot <= undershoot ? fitting : fitting + 1
        }
        size = max(1, imageWidth(columns))
    }

    var gridItems: [GridItem] {
        Array(repeating: GridItem(.fixed(size), spacing: Self.columnSpacing), count: columns)
    }
}

/// 読み込み失敗時の案内。ガラスのカードに載せて背景と区別する。
struct LoadErrorView: View {
    let message: String
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(.pink)
            Text("読み込めませんでした").font(.headline)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("再試行") {
                isRetrying = true
                Task {
                    await retry()
                    isRetrying = false
                }
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.white)
            .disabled(isRetrying)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - 検索欄とナビゲーションバーの余白

/// iPad の drawer は split detail の端まで広がり、navigation bar の余白も継がない。
/// 正確な detail 余白を保つ必要があるため、iPad だけ検索欄を自前で配置する。
private struct LibrarySearchField: UIViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField()
        field.placeholder = prompt
        field.returnKeyType = .search
        field.delegate = context.coordinator
        field.clearButtonMode = .whileEditing
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholder = prompt
        // 変換途中の文字を SwiftUI の再評価で壊さない。
        guard field.markedTextRange == nil, field.text != text else { return }
        // 再評価は入力より遅れて届くので、この欄が自分で送った値が古いまま返ってくる。
        // 速く打つと「Ray」が「R」に戻るのはこれ。ただし編集中を丸ごと除くと、sidebar の
        // 検索を選び直したときの `searchQuery = ""` まで届かなくなる。そこで「自分が送った値」
        // だけを無視し、外から来た値は編集中でも反映する。
        // 送った順に消すのは、編集中に一度空にした履歴が残ったままだと、
        // 後から来た外部の空文字まで自分の echo と見なして無視してしまうため。
        if let echo = context.coordinator.sentTexts.firstIndex(of: text) {
            context.coordinator.sentTexts.removeFirst(echo + 1)
            return
        }
        field.text = text
        context.coordinator.sentTexts.removeAll()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UISearchTextField,
        context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? uiView.intrinsicContentSize.width,
            height: uiView.intrinsicContentSize.height
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        /// この欄が binding へ送った値を送った順に憶える。遅れて返ってくる再評価を外からの変更と見分ける。
        var sentTexts: [String] = []

        init(text: Binding<String>) { self.text = text }

        @objc func textChanged(_ field: UISearchTextField) {
            let current = field.text ?? ""
            sentTexts.append(current)
            text.wrappedValue = current
        }

        /// 検索キーでキーボードを閉じる。閉じないと iPad では結果の下半分が隠れたままになる。
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        /// 編集を抜けたら憶えた値を捨てる。次の編集まで持ち越すと、外からの変更を取りこぼす。
        func textFieldDidEndEditing(_ textField: UITextField) {
            sentTexts.removeAll()
        }
    }
}

extension View {
    /// iPhone は標準 drawer、iPad は detail 本文と同じ 34.5 pt に検索欄そのものを揃える。
    @ViewBuilder
    func librarySearchable(
        text: Binding<String>,
        prompt: LocalizedStringResource,
        horizontalMargin: CGFloat
    ) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            safeAreaInset(edge: .top, spacing: 0) {
                LibrarySearchField(text: text, prompt: String(localized: prompt))
                    .padding(.horizontal, horizontalMargin)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    // 地は黒一色で、detail に板のような面は敷かない（仕様 6 章）。`.bar` の material は
                    // 上端に半透明の帯を作り、split view では窓幅いっぱい（板の上まで）広がってしまう。
                    // 透かさず黒で塞ぐことで、下をくぐる本文も見せない。
                    .background(Color.black)
            }
        } else {
            searchable(
                text: text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(prompt)
            )
        }
    }
}

/// 画面名はナビゲーションバーが描くので、SwiftUI 側の padding では左右を動かせない。
/// バーは既定で iPhone の最小余白 16 pt に従うため、バー自身のレイアウト余白を 20 pt へ上書きする（仕様 1.1 章）。
private struct NavigationBarMargins: UIViewRepresentable {
    let horizontal: CGFloat

    func makeUIView(context: Context) -> UIView { MarginView() }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? MarginView else { return }
        view.horizontal = horizontal
        view.apply()
    }

    /// 生成時点ではまだ階層に入っていないので、窓に入ってから responder chain を辿って反映する。
    private final class MarginView: UIView {
        var horizontal: CGFloat = 20

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard window != nil else { return }
            var responder: UIResponder? = next
            while let current = responder {
                if let navigation = current as? UINavigationController {
                    let bar = navigation.navigationBar
                    // 安全領域からの再計算で 16 pt へ戻されないよう、継承を切ってから直に指定する。
                    bar.insetsLayoutMarginsFromSafeArea = false
                    bar.preservesSuperviewLayoutMargins = false
                    bar.directionalLayoutMargins.leading = horizontal
                    bar.directionalLayoutMargins.trailing = horizontal
                    bar.setNeedsLayout()
                    return
                }
                responder = current.next
            }
        }
    }
}

extension View {
    /// 画面名と検索欄の左右を、一覧本体と同じ 20 pt に揃える（仕様 1.1 章）。
    func libraryNavigationMargins(_ horizontal: CGFloat = 20) -> some View {
        background(NavigationBarMargins(horizontal: horizontal))
    }
}
