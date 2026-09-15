import SwiftUI

// MARK: - 行送りの動き方

/// 歌詞が次の行へ送られるときの動き方。**実機で見比べるための一時的な切り替え**で、
/// どれが Apple Music に近いか決まったら 1 つだけ残して畳む（仕様 5.2 章）。
/// 保存先を `Core/Settings/` に足さず `@AppStorage` にしているのは、
/// 比較が済んだら消す設定を再生の設定と同じ器に混ぜないため。
nonisolated enum LyricsScrollAnimation: String, CaseIterable, Identifiable {
    /// 弾まない加減速。現行の挙動で、これを既定にする。
    case easeInOut
    /// ばねだが行き過ぎない。加減速との差は終わり際の詰まり方だけになる。
    case smooth
    /// preset が持つ 0.15 の弾みで、行き過ぎてから戻る。
    case snappy
    /// preset が持つ 0.3 の弾みで、はっきり行き過ぎる。
    case bouncy

    /// `@AppStorage` のキー。設定画面と歌詞本文の 2 か所から同じ値を読むので一つ置く。
    static let storageKey = "lyrics.scroll.animation"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easeInOut: String(localized: "加減速（現行）")
        case .smooth: String(localized: "弾まないばね")
        case .snappy: String(localized: "小さく弾むばね")
        case .bouncy: String(localized: "大きく弾むばね")
        }
    }

    /// `extraBounce: 0` は「弾まない」ではなく「**preset 自身の弾みに上乗せしない**」の意味で、
    /// `.snappy` は 0.15、`.bouncy` は 0.3 の弾みが残る。3 つのばねはそこだけが違う。
    var animation: Animation {
        switch self {
        case .easeInOut: .easeInOut(duration: 0.3)
        case .smooth: .smooth(duration: 0.3, extraBounce: 0)
        case .snappy: .snappy(duration: 0.3, extraBounce: 0)
        case .bouncy: .bouncy(duration: 0.3, extraBounce: 0)
        }
    }
}

/// 操作帯の判定に使う `ScrollView` の幾何（仕様 5.1 章 第 4 版）。
/// 縦位置と器の大きさを**同じ観測で一緒に受け取る**ためだけの型で、両者の届く順序に
/// 判定が左右されないようにする。**末尾の境界もここで出す**ので、内容の高さと差し込みも同じ観測に含める。
private nonisolated struct LyricsScrollProbe: Equatable {
    /// `contentInsets.top` を足して内容の先頭を 0 に揃えた縦位置。
    var offset: CGFloat
    var containerSize: CGSize
    var contentHeight: CGFloat
    /// 上下の差し込みの合計。器の高さから引くと、内容が実際に動ける幅が出る。
    var verticalInsets: CGFloat

    /// 末尾まで送り切った位置。`offset` がこれを超えている間は、ゴムで引き伸ばされているだけで
    /// 内容の続きを見ている訳ではない。
    var maximumOffset: CGFloat { max(0, contentHeight + verticalInsets - containerSize.height) }

    /// 末尾の境界に張り付いているか。ここに居る間だけ、境界が動くと指を止めていても `judgedOffset` が動く。
    var isAtBottomBoundary: Bool { offset >= maximumOffset }

    /// 境界が動いたせいで判定に使う位置が動く回かどうか（仕様 5.1 章 第 5 版）。
    /// **境界の内側を普通に読んでいる間は数え続ける。**そこでは `judgedOffset` が `offset` そのもので、
    /// `LazyVStack` が行の見積もりを実測へ入れ替えて境界が動いても判定は揺れない。
    /// この区別を付けずに境界の変化だけで基準を捨てると、速い送りの最中は見積もりの入れ替えが続くので
    /// 積算が溜まる前に何度も捨てられ、**帯が隠れなくなる**（実機大の録画で確認）。
    static func boundaryMoved(from old: Self, to new: Self) -> Bool {
        // 末尾で挟まれている回だけが危ない。入る直前と出た直後のどちらも拾えるよう両方を見る。
        // 境界の比較には許容を入れない。小さな単調変化でも積もれば帯を出す量になるため、
        // `CGFloat` が別の値になった回をその都度捨てて累積への入口を塞ぐ。
        return old.maximumOffset != new.maximumOffset
            && (old.isAtBottomBoundary || new.isAtBottomBoundary)
    }

    /// 判定に使う位置。**器の外へ出たぶんは境界へ張り付かせる**（仕様 5.1 章 第 5 版）。
    /// 末尾で弾んで戻ってくる間はこの値が動かないので、戻りを「上へ送った」と読むことがなくなる。
    /// 末尾から本当に指で戻せば境界の内側へ入るため、利用者の意思はそのまま残る。
    var judgedOffset: CGFloat { min(max(offset, 0), maximumOffset) }
}

/// 読む位置を安定させるため、強調は文字の濃淡に留め、行の大きさを変えない。
struct LyricsView: View {
    let track: MediaItem
    /// 上部の切り替えが終わっているか（仕様 5.1 章）。false の間は初回の位置合わせを保留する。
    var isSettled = true
    /// 操作帯を隠すかどうかの変化だけを外へ知らせる（仕様 5.1 章 第 4 版）。
    /// 帯を実際に動かすのは `NowPlayingView` 側で、ここは「読み進めたか / 戻ったか」の判定だけを持つ。
    var onControlsVisibilityChange: (Bool) -> Void = { _ in }

    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// ぼかしは読みやすさを落とす飾りなので、「透明度を下げる」設定では外す（仕様 5.2 章）。
    /// この設定を見るのはアプリ内でここだけだが、ぼかしを入れたのもここだけなので方針は揃っている。
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 行送りの動き方の比較設定（仕様 5.2 章）。決まったら 1 つだけ残して畳む。
    @AppStorage(LyricsScrollAnimation.storageKey) private var scrollAnimation = LyricsScrollAnimation.easeInOut
    /// 比較用の暫定値（仕様 5.2 章）。**Apple 実機の実測値ではない。**
    /// 固定値や `.custom` にせず `@ScaledMetric` に持たせるのは、Dynamic Type へ追従させるため。
    @ScaledMetric(relativeTo: .title) private var lyricSize = 32.0
    @ScaledMetric(relativeTo: .title) private var lyricSpacing = 12.0
    /// 現在行以外に掛けるぼかし（仕様 5.2 章）。**`docs/org/movie.mov` から測った値**で、
    /// 文字と一緒に伸びるよう `lyricSize` と同じ尺に載せる。測り方は仕様 5.2 章に書いた。
    @ScaledMetric(relativeTo: .title) private var lyricBlur = 1.7
    @State private var lines: [LyricLine] = []
    @State private var isLoading = true
    @State private var isFollowing = true
    /// 初回の位置合わせを済ませたか。曲を読み直すまで一度だけ行う。
    @State private var hasAligned = false
    @State private var errorMessage: String?
    /// 追従へ戻すための待ち。操作が続いている間は測り直すので、常に 1 本だけ持って差し替える。
    @State private var resumeTask: Task<Void, Never>?
    /// プログラムが動かしているスクロールの猶予。走っている間は操作帯の判定を丸ごと止める。
    @State private var programmaticScroll: Task<Void, Never>?
    /// 操作帯の出し入れが落ち着くまでの猶予（仕様 5.1 章 第 4 版）。帯を退避させると
    /// **この本文自身の器が 300 pt 伸び縮みする**ので、その間に届く位置の変化は利用者が送ったものではない。
    /// `programmaticScroll` と分けて持つのは、あちらが**指が触れた時点で打ち切られる**ため。
    /// 帯を動かすのは指が送っている最中なので、同じ器に載せると立てた端から消える。
    @State private var controlsSettling: Task<Void, Never>?
    /// 操作帯の判定に使う縦位置と、同じ向きへ積んだ量（仕様 5.1 章 第 4 版）。
    @State private var lastJudgedOffset: CGFloat?
    @State private var scrollAccumulation: CGFloat = 0
    /// いま操作帯を隠しているか。外へ渡すのはこの値が変わったときだけにする。
    @State private var controlsHidden = false
    /// 指が送っている最中か。`.tracking` や `.animating` を除くための印。
    @State private var isJudgingScroll = false

    /// 手を止めてから自動追従へ戻るまで（仕様 5.2 章）。**Apple 実機の実測値ではない暫定値。**
    /// 読み返している最中に画面を奪い返さず、かつ放置されたまま追従が死なない長さとして置いた。
    private static let followResumeDelay = Duration.seconds(3)

    /// プログラムのスクロールを判定から外しておく時間（仕様 5.1 章 第 4 版）。
    /// 位置合わせのアニメーション 0.3 秒に余裕を足しただけの値で、**Apple 実機の実測値ではない**。
    /// `.animating` が `.idle` へ落ちた時点で解く手もあるが、「視差効果を減らす」設定では
    /// `withAnimation(nil)` になって `.animating` を経由しないので、段階ではなく時間で区切る。
    private static let programmaticScrollGrace = Duration.milliseconds(450)

    /// 操作帯の出し入れを判定から外しておく時間（仕様 5.1 章 第 4 版）。
    /// **本文の器が伸び縮みするのは即時だが、そこから出る位置の押し戻しは即時では終わらない。**
    /// 行き過ぎたぶんは弾みを伴って数フレームに渡って戻ってくるうえ、指はまだ送っている。
    /// 長さは帯の 0.4 秒に `programmaticScrollGrace` と同じ余裕を足した値にして、
    /// 2 つの猶予を同じ組みの数値で揃えた。**Apple 実機の実測値ではない。**
    /// 起点は帯の状態を変えた時点**と、器が実際に動いた時点の両方**（仕様 5.1 章 第 5 版）。
    /// 本文が場所を受け取るのが帯より後になったので、前者だけでは押し戻しが猶予の外へはみ出す。
    private static let controlsSettleGrace = Duration.milliseconds(550)

    /// 下へ 32 pt 送ったら操作帯を隠し、上へ 16 pt 戻したら出す（仕様 5.1 章 第 4 版）。
    /// **どちらも Musicfin の決定値で、Apple 実機の実測値ではない。**
    /// 戻すほうを小さくするのは、隠すのは読み進めたついででよいが、操作へ戻りたいときは
    /// 一度の小さな引き戻しで出したいため。速度は見ない（弾きの強さで結果が変わらないようにする）。
    private static let hideThreshold: CGFloat = 32
    private static let showThreshold: CGFloat = 16
    /// 先頭と見なす幅。ぴったり 0 を要求すると、弾みで 1 pt 残っただけで戻らなくなる。
    private static let topSlack: CGFloat = 1

    /// 現在行を本文の上端寄りに置く（仕様 5.2 章）。`.top` ちょうどだと現在行が縁に貼り付いて窮屈で、
    /// 直前に歌った行も見えなくなる。1 行ぶんだけ上を覗かせる位置として 0.15 を採る。
    private static let activeLineAnchor = UnitPoint(x: 0, y: 0.15)

    private var isSynced: Bool { lines.contains { $0.startSeconds != nil } }

    /// 現在行は「再生位置以下で開始時刻が最大の行」（仕様 5.2 章）。
    /// 以前の `lastIndex` は「配列の後ろほど新しい時刻」を前提にしていたが、
    /// 並びは取得元の都合で、時刻順である保証がない。順序に寄りかからず最大値で選ぶ。
    private func activeIndex(at time: TimeInterval) -> Int? {
        var best: Int?
        var bestStart = -TimeInterval.infinity
        for (index, line) in lines.enumerated() {
            guard let start = line.startSeconds, start <= time, start >= bestStart else { continue }
            best = index
            bestStart = start
        }
        return best
    }

    /// 再生位置と現在行は **`body` の評価時にここで一度だけ読む**（仕様 5.2 章）。
    /// 各行のクロージャの中で `player.currentTime` を読むと、行の再評価が `body` の観測から外れて
    /// 更新の届き方が構成に左右される。強調・選択状態・追従へは、必ずこの同じ値を配る。
    var body: some View {
        let active = activeIndex(at: player.currentTime)
        return Group {
            if isLoading {
                ProgressView("歌詞を読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ScrollView {
                    LoadErrorView(message: errorMessage) { await load() }
                }
            } else if lines.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        Text("歌詞がありません").font(.headline)
                        Text("この曲には歌詞が登録されていません。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                lyricsList(activeIndex: active)
            }
        }
        .task(id: track.id) { await load() }
    }

    private func lyricsList(activeIndex active: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: lyricSpacing) {
                    // 時刻の無い歌詞では現在行が決まらない。全行を強調して「どれも現在行」に見せるより、
                    // 追従できない歌詞だと先に断る（仕様 5.2 章）。時刻は作らない。
                    if !isSynced {
                        Text("この歌詞には時間情報がありません。再生に合わせた自動追従は行いません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Group {
                            if let start = line.startSeconds {
                                Button {
                                    // 行タップは「ここへ飛ぶ」意思表示なので、追従を切ったままにしない。
                                    // タップでも指は触れるので `.tracking` で `isFollowing` が落ちており、
                                    // ここで戻さないと飛び先へ合わせ直すのが復帰の 3 秒後になる（仕様 5.2 章）。
                                    isFollowing = true
                                    resumeTask?.cancel()
                                    resumeTask = nil
                                    player.seek(to: start)
                                } label: {
                                    lineText(line, active: index == active, hasActiveLine: active != nil)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("この行の再生位置へ移動")
                                .accessibilityAddTraits(index == active ? .isSelected : [])
                            } else {
                                // 時刻が無ければ飛び先も無いので、押せる行にしない（仕様 5.2 章）。
                                lineText(line, active: false, hasActiveLine: active != nil)
                            }
                        }
                        .id(index)
                    }
                }
                // **上に余白は置かない**（仕様 5.2 章）。参照では上の小アートワークの帯から本文が
                // そのまま続いていて、先頭行は帯のすぐ下から入って上端へ抜けていく。ここへ余白を足すと
                // 帯の下に空白の段ができ、抜けていく行が途中から現れる別の見え方になる。
                // 下の 24 pt は最終行が操作帯へ貼り付かないための余白なので残す。
                .padding(.bottom, 24)
                // 同じ画面の小アートワークや曲名と同じ左右 32 pt に載せる（仕様 5 章）。外側の 24 pt との差。
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                // 自動追従のアニメーションでは止めず、ユーザーが触れた時点で読む位置を尊重する。
                if phase == .tracking || phase == .interacting {
                    isFollowing = false
                    // まだ触っている間は数えない。指を置き直すたびに待ち時間を測り直す。
                    resumeTask?.cancel()
                    resumeTask = nil
                    // 指が触れた以上、プログラムが動かしていたスクロールはそこで終わり。猶予を残したままだと
                    // 利用者が送っているぶんまで判定から外れる（仕様 5.1 章 第 4 版）。
                    programmaticScroll?.cancel()
                    programmaticScroll = nil
                }
                // 操作帯の判定は「指が送っている `.interacting`」と、**それに続く惰性**だけで行う。
                // 指が乗っただけの `.tracking`、プログラムの `.animating`、静止した `.idle` は数えない。
                // 惰性を直前の送りの続きとしてだけ認めるので、`isJudgingScroll` を条件に噛ませる。
                let judging = phase == .interacting || (phase == .decelerating && isJudgingScroll)
                if judging != isJudgingScroll {
                    isJudgingScroll = judging
                    // 数え始めと数え終わりで積算を捨てる。前の送りの残りを次の送りへ持ち越さない。
                    scrollAccumulation = 0
                }
                // 慣性が止まりきってからが「手を止めた」時点。`.decelerating` の間はまだ数えない。
                if phase == .idle { scheduleFollowResume(proxy: proxy) }
            }
            // 位置は段階ではなくここで読む。`.interacting` の間は phase が変わらないので、
            // 段階の変化だけを見ていると送った量が分からない（仕様 5.1 章 第 4 版）。
            // **位置と器の大きさは 1 つの観測にまとめる。**別々の `onScrollGeometryChange` に
            // 分けていたときは、同じ更新で両方が変わってもどちらの処理が先に走るか決まらず、
            // 器が伸びたせいの位置の変化を先に「送った量」として数えてしまう隙があった。
            .onScrollGeometryChange(for: LyricsScrollProbe.self) { geometry in
                // `contentInsets.top` を足して**内容の先頭を 0** に揃える。そうしないと先頭でも 0 にならず、
                // 「先頭まで戻したら操作帯を出す」が成立しない。
                LyricsScrollProbe(
                    offset: geometry.contentOffset.y + geometry.contentInsets.top,
                    containerSize: geometry.containerSize,
                    contentHeight: geometry.contentSize.height,
                    verticalInsets: geometry.contentInsets.top + geometry.contentInsets.bottom
                )
            } action: { old, new in
                // 器の大きさが変わった回は数えない。文字の拡大や画面の向きに加え、
                // **操作帯の退避でこの本文自身が伸び縮みする**ときもここへ来る。
                // その回の差分は送った量ではないので、基準だけ置き直して捨てる。
                // **末尾で境界そのものが動いた回も同じ**（仕様 5.1 章 第 5 版）。`LazyVStack` が見積もりを
                // 実測へ入れ替えたときなど、器はそのままでも境界だけが下がることがあり、
                // 末尾で引き伸ばされている最中なら指が止まっていても挟んだ位置が一緒に下がる。
                // それを「上へ送った」と読むと操作帯が勝手に戻るので、ここで基準を置き直す。
                guard old.containerSize == new.containerSize,
                    !LyricsScrollProbe.boundaryMoved(from: old, to: new)
                else {
                    lastJudgedOffset = new.judgedOffset
                    scrollAccumulation = 0
                    // 器や境界が変わった**あと**に来る押し戻しも数えない（仕様 5.1 章 第 5 版）。
                    // 帯の状態を変えた時点から測るだけでは、本文が伸びるのが帯の 0.4 秒より後になった今、
                    // 押し戻しが猶予の外へはみ出す。実際に器が動いた時点から測り直す。
                    beginControlsSettling()
                    return
                }
                judgeControls(offset: new.judgedOffset)
            }
            // **`isFollowing` が止めるのはスクロールだけ**（仕様 5.2 章）。過去の歌詞を手で読んでいる間も
            // 現在行の算出と強調は続くので、ここの `guard` は `scroll` の手前にしか置かない。
            .onChange(of: active) { _, index in
                guard hasAligned, isFollowing, let index else { return }
                scroll(to: index, proxy: proxy)
            }
            // 初回だけは上部の切り替えが終わってから合わせる（仕様 5.1 章）。
            // 遷移中に動かすと、対応付けた画像と本文が別の速さで流れて二重に見える。
            .onChange(of: isSettled, initial: true) { _, settled in
                guard settled, !hasAligned else { return }
                hasAligned = true
                guard isFollowing, let active else { return }
                scroll(to: active, proxy: proxy)
            }
            // 画面外へ出た本文の待ちは残さない。曲を跨いだ復帰は `load()` 側で断つ。
            .onDisappear {
                resumeTask?.cancel()
                resumeTask = nil
                programmaticScroll?.cancel()
                programmaticScroll = nil
                controlsSettling?.cancel()
                controlsSettling = nil
            }
        }
    }

    /// 送った向きと量だけで操作帯の出し入れを決める（仕様 5.1 章 第 4 版）。
    /// 速度を見ないのは、同じだけ送ったのに弾きの強さで結果が変わるのを避けるため。
    /// 受け取るのは **`LyricsScrollProbe.judgedOffset`（先頭と末尾で挟んだ位置）**で、
    /// 器の外へ引き伸ばされたぶんはここへ届く前に落ちている（仕様 5.1 章 第 5 版）。
    private func judgeControls(offset: CGFloat) {
        // **帯を動かした直後も判定を止める**（仕様 5.1 章 第 4 版）。帯の退避は本文の高さを
        // 300 pt 変えるので、下まで読んでいると収まりきらなくなった位置がまとめて押し戻される。
        // これを送りと取り違えると、隠した直後に「上へ 16 pt 戻した」と読んで帯が出直し、
        // 出しては隠すの往復が始まる。器の大きさで弾くだけでは足りないのは、**高さの変更は即時でも
        // 押し戻しは弾みを伴い**、大きさの変化とは別の回に届くため。
        // **先頭へ戻したときの近道より手前**に置く。あちらは積算を見ないので、押し戻しで
        // 0 付近まで下がっただけでも帯を出してしまう。
        guard controlsSettling == nil else {
            lastJudgedOffset = offset
            scrollAccumulation = 0
            return
        }
        // **プログラムが動かしている間は判定そのものを止める。**追従の復帰・初回の位置合わせ・
        // 行タップ後の合わせは位置を大きく飛ばすので、利用者の送りと取り違えると帯が勝手に消える。
        // 呼び出し元ごとに積算を戻して回ると必ずどれか漏れるため、`scroll(to:proxy:)` に一本化した
        // この印だけを見る。飛んだ先を次の基準にして、差分が二重に効かないようにしておく。
        guard programmaticScroll == nil else {
            lastJudgedOffset = offset
            scrollAccumulation = 0
            return
        }
        // 先頭まで戻したら、積算がいくつでも操作帯を出す。先頭は読み進めている途中ではなく、
        // 曲を見渡している位置なので、ここで隠れたままにする理由がない。
        if offset <= Self.topSlack {
            lastJudgedOffset = offset
            scrollAccumulation = 0
            setControlsHidden(false)
            return
        }
        // 数えない段階でも基準だけは追う。ここを放っておくと、次に送り始めた瞬間に
        // 数えていなかった間の移動量がまとめて差分として出る。
        guard isJudgingScroll else {
            lastJudgedOffset = offset
            return
        }
        let delta = offset - (lastJudgedOffset ?? offset)
        lastJudgedOffset = offset
        guard delta != 0 else { return }
        // 向きが変わったら積み直す。上下に行き来しているだけの指で閾値へ届かせない。
        if scrollAccumulation * delta < 0 { scrollAccumulation = 0 }
        scrollAccumulation += delta
        if scrollAccumulation >= Self.hideThreshold {
            setControlsHidden(true)
            scrollAccumulation = 0
        } else if scrollAccumulation <= -Self.showThreshold {
            setControlsHidden(false)
            scrollAccumulation = 0
        }
    }

    private func setControlsHidden(_ hidden: Bool) {
        guard controlsHidden != hidden else { return }
        controlsHidden = hidden
        // 猶予は**外へ渡す前**に立てる。渡した先で本文の高さが変わり、その位置の変化が
        // 同じ更新のうちに返ってくることがあるので、後から立てると 1 回ぶん取りこぼす。
        beginControlsSettling()
        onControlsVisibilityChange(hidden)
    }

    /// 帯や器が動いたあとの落ち着くまでを判定から外す（仕様 5.1 章 第 4・5 版）。
    /// 立て直しなので、走っている猶予があれば必ず差し替える。
    private func beginControlsSettling() {
        controlsSettling?.cancel()
        controlsSettling = Task {
            try? await Task.sleep(for: Self.controlsSettleGrace)
            guard !Task.isCancelled else { return }
            controlsSettling = nil
            // 明けた時点の位置を次の基準にし直すのは `judgeControls` の側。ここで積算だけ捨てておく。
            scrollAccumulation = 0
        }
    }

    /// 手で読んでいる間は追従を止めるが、そのままだと二度と戻らない。
    /// 復帰用のボタンを出す代わりに、操作が終わってしばらく経ったら自分で追従へ戻る（仕様 5.2 章）。
    private func scheduleFollowResume(proxy: ScrollViewProxy) {
        // 時刻のない歌詞はそもそも追従しないので、待ちも持たない。
        guard isSynced, !isFollowing else { return }
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(for: Self.followResumeDelay)
            guard !Task.isCancelled else { return }
            resumeTask = nil
            isFollowing = true
            // 待っている間に曲は進んでいる。`body` が読んだ値ではなく、**戻る時点**の再生位置で選び直す。
            scroll(to: activeIndex(at: player.currentTime) ?? 0, proxy: proxy)
        }
    }

    /// 全行で同じ大きさ・同じウェイトにする。現在行だけ大きくすると行高が変わり、
    /// 追従のたびに前後の行が動いて読む位置を見失う（ファイル冒頭の方針・仕様 5.2 章）。
    /// 濃淡は `.primary` / `.secondary` のまま。**濃さの係数は測れていないので足さない**が、
    /// ぼかしだけは参照録画から逆算できたので入れてある（仕様 5.2 章）。
    /// 段内に `lineSpacing` を足さないのも同じ理由で、項目間隔だけで間を作る。
    private func lineText(_ line: LyricLine, active: Bool, hasActiveLine: Bool) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: lyricSize, weight: .bold))
            .foregroundStyle(active ? .primary : .secondary)
            // ぼかすのは**文字だけ**。`.frame` と `.contentShape` より前に掛けることで、
            // 押せる範囲と読み上げの範囲はぼかしても動かない。
            .blur(radius: blurRadius(active: active, hasActiveLine: hasActiveLine))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // 44 pt はタップ領域の下限。文字が大きくなれば行の高さはそちらに従って伸びる。
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
    }

    /// ぼかすのは**自動で追い掛けている間の、現在行以外だけ**（仕様 5.2 章）。
    /// 手で送っている間に外すのは、そのとき読みたいのは現在行ではなく指が止めた場所だから。
    /// **現在行が決まっていなければ掛けない**。時刻の無い歌詞はもちろん、時刻付きでも
    /// 前奏のように再生位置が最初の行より前だと現在行は無く、掛ければ全行がぼけてしまう。
    private func blurRadius(active: Bool, hasActiveLine: Bool) -> CGFloat {
        guard isSynced, isFollowing, hasActiveLine, !active, !reduceTransparency else { return 0 }
        return lyricBlur
    }

    /// 位置合わせは**すべてここを通す**（仕様 5.1 章 第 4 版）。初回の位置合わせ・現在行の追従・
    /// 追従への復帰・行タップ後の合わせは、どれも利用者が送ったのではない移動なので、
    /// 「プログラムが動かしている間は判定しない」を各呼び出し元ではなくこの 1 か所で立てる。
    private func scroll(to index: Int, proxy: ScrollViewProxy) {
        programmaticScroll?.cancel()
        programmaticScroll = Task {
            try? await Task.sleep(for: Self.programmaticScrollGrace)
            guard !Task.isCancelled else { return }
            programmaticScroll = nil
        }
        // 動き方は比較設定から採る（仕様 5.2 章）。**「視差効果を減らす」設定が優先**で、
        // そのときは設定の値にかかわらず補間しない。操作帯の出し入れと本文の伸縮は
        // 状態切り替えと揃える別の動きなので、この設定の対象にしない。
        withAnimation(reduceMotion ? nil : scrollAnimation.animation) {
            proxy.scrollTo(index, anchor: Self.activeLineAnchor)
        }
    }

    private func load() async {
        isLoading = true
        isFollowing = true
        hasAligned = false
        // 前の曲の行番号へ戻そうとする待ちが残っていると、新しい歌詞を読み込んだ直後に飛ばされる。
        resumeTask?.cancel()
        resumeTask = nil
        programmaticScroll?.cancel()
        programmaticScroll = nil
        controlsSettling?.cancel()
        controlsSettling = nil
        isJudgingScroll = false
        scrollAccumulation = 0
        lastJudgedOffset = nil
        // 曲が替わったら操作帯は出した状態から始める。`.id(track.id)` で作り直される側は
        // 自分が隠したことを覚えていないので、`setControlsHidden` を通さず毎回伝える。
        controlsHidden = false
        onControlsVisibilityChange(false)
        errorMessage = nil
        lines = []
        defer { if !Task.isCancelled { isLoading = false } }
        guard let client = auth.client else {
            errorMessage = String(localized: "サーバーに接続してから、もう一度お試しください。")
            return
        }
        do {
            let fetched = try await client.fetchLyrics(itemID: track.id) ?? []
            try Task.checkCancellation()
            lines = fetched.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? fetched : []
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

#Preview {
    LyricsView(track: MediaItem(id: "preview-track", name: "夜の散歩", type: .audio))
        .environment(AuthStore())
        .environment(PlaybackEngine())
        .frame(height: 320)
        .padding()
}
