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
        case .easeInOut: String(localized: "加減速")
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
    /// 文字サイズなどの更新で内容の高さが変わっても、実際の送りを途中で捨てずに済む。
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
    /// バーの操作中とシークの着地待ちは、再生による自然な行送りと区別する。
    var isSeeking = false
    /// 操作帯の退避後に本文が下へ伸びた量。初期位置の上余白は伸びる前の高さから決め、
    /// 本文が場所を受け取っても上部と読む位置を動かさない。
    var bottomExtension: CGFloat = 0
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
    /// プログラムが動かしているスクロールの猶予。走っている間は操作帯の判定を丸ごと止める。
    @State private var programmaticScroll: Task<Void, Never>?
    @State private var scrollLag: LyricsRollMotion?
    @State private var rollCompletion: Task<Void, Never>?
    @State private var currentScrollOffset: CGFloat = 0
    @State private var directAlignmentUntil: TimeInterval = 0
    @State private var introPosition = ScrollPosition()
    @State private var controlsScroll = LyricsControlsScroll()
    @GestureState private var isDraggingGesture = false
    @State private var scrollPhase = ScrollPhase.idle
    @State private var visibleLineIndices: Set<Int> = []
    /// いま操作帯を隠しているか。外へ渡すのはこの値が変わったときだけにする。
    @State private var controlsHidden = false
    /// 指の送りと、それに続く惰性を判定しているか。通常の長い歌詞では惰性も送りとして数える。
    @State private var isJudgingScroll = false
    /// 指が画面上で実際に送っている間だけの印。通常の geometry は惰性も届くため分けて持つ。
    @State private var isInteractingScroll = false
    @State private var hasScrollableRange = true

    /// プログラムのスクロールを判定から外しておく時間（仕様 5.1 章 第 4 版）。
    /// 位置合わせのアニメーション 0.3 秒に余裕を足しただけの値で、**Apple 実機の実測値ではない**。
    /// `.animating` が `.idle` へ落ちた時点で解く手もあるが、「視差効果を減らす」設定では
    /// `withAnimation(nil)` になって `.animating` を経由しないので、段階ではなく時間で区切る。
    private static let programmaticScrollGrace = Duration.milliseconds(450)

    /// 先頭と見なす幅。ぴったり 0 を要求すると、弾みで 1 pt 残っただけで戻らなくなる。
    private static let topSlack: CGFloat = 1

    /// 現在行を本文の上端寄りに置く（仕様 5.2 章）。`.top` ちょうどだと現在行が縁に貼り付いて窮屈で、
    /// 直前に歌った行も見えなくなる。1 行ぶんだけ上を覗かせる位置として 0.15 を採る。
    private static let activeLineTopRatio: CGFloat = 0.15
    private static let activeLineAnchor = UnitPoint(x: 0, y: activeLineTopRatio)
    private static let introID = -1

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
        let position = player.currentTime
        let active = activeIndex(at: position)
        return Group {
            // 初回の全行配置を上部の縮小と重ねず、配置済みの本文は操作中もそのまま保つ。
            if isLoading || (!isSettled && !hasAligned && !lines.isEmpty) {
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
                lyricsList(activeIndex: active, position: position)
            }
        }
        .task(id: track.id) { await load() }
    }

    private func lyricsList(activeIndex active: Int?, position: TimeInterval) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: scrollLag == nil || reduceMotion)) {
                        context in
                        lyricsContent(
                            active: active, viewportHeight: viewport.size.height,
                            at: context.date.timeIntervalSinceReferenceDate)
                    }
                }
                .scrollPosition($introPosition)
                .scrollIndicators(.hidden)
                // 器の伸縮による補正は、その更新とは別の geometry 通知でも届く。指の間は
                // 長さに関係なく translation だけを数え、ScrollView 自身の位置補正から独立させる。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isDraggingGesture) { _, dragging, _ in dragging = true }
                        .onChanged { value in
                            if !controlsScroll.isDragging {
                                cancelRoll()
                                introPosition.isPositionedByUser = true
                                programmaticScroll?.cancel()
                                programmaticScroll = nil
                            }
                            isFollowing = false
                            if let hidden = controlsScroll.drag(
                                to: Double(value.translation.height),
                                isAtTop: hasScrollableRange && currentScrollOffset <= Self.topSlack)
                            {
                                setControlsHidden(hidden)
                            }
                        }
                        .onEnded { _ in
                            controlsScroll.endDragging()
                            if scrollPhase == .idle {
                                controlsScroll.stop()
                                reacquireFollowIfVisible(proxy: proxy)
                            }
                        }
                )
                .onChange(of: isDraggingGesture) { _, dragging in
                    // システムによる取消では onEnded が来ない。成功時は既に所有を放しているので、
                    // 取消だけを片付ければ通常の指離しから続く慣性の積算は残せる。
                    guard !dragging, controlsScroll.isDragging else { return }
                    controlsScroll.stop()
                    reacquireFollowIfVisible(proxy: proxy)
                }
                .onScrollPhaseChange { _, phase in
                    scrollPhase = phase
                    // 自動追従のアニメーションでは止めず、ユーザーが触れた時点で読む位置を尊重する。
                    if phase == .tracking || phase == .interacting {
                        cancelRoll()
                        introPosition.isPositionedByUser = true
                        isFollowing = false
                        // 指が触れた以上、プログラムが動かしていたスクロールはそこで終わり。猶予を残したままだと
                        // 利用者が送っているぶんまで判定から外れる（仕様 5.1 章 第 4 版）。
                        programmaticScroll?.cancel()
                        programmaticScroll = nil
                    }
                    // 操作帯の判定は「指が送っている `.interacting`」と、**それに続く惰性**だけで行う。
                    // 指が乗っただけの `.tracking`、プログラムの `.animating`、静止した `.idle` は数えない。
                    // 惰性を直前の送りの続きとしてだけ認めるので、`isJudgingScroll` を条件に噛ませる。
                    isInteractingScroll = phase == .interacting
                    let judging = isInteractingScroll || (phase == .decelerating && isJudgingScroll)
                    if judging != isJudgingScroll {
                        isJudgingScroll = judging
                    }
                    // 慣性が止まるまで読む位置を奪わず、現在行が実際に見えているときだけ追従を取り直す。
                    if phase == .idle {
                        if !controlsScroll.isDragging { controlsScroll.stop() }
                        finishRoll(after: .milliseconds(170))
                        reacquireFollowIfVisible(proxy: proxy)
                    }
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
                    currentScrollOffset = new.offset
                    scrollLag?.record(offset: Double(new.offset), time: Date.now.timeIntervalSinceReferenceDate)
                    if old.containerSize != new.containerSize {
                        cancelRoll()
                    }
                    // 器の大きさが変わった回は数えない。文字の拡大や画面の向きに加え、
                    // **操作帯の退避でこの本文自身が伸び縮みする**ときもここへ来る。
                    // その回の差分は送った量ではないので、基準だけ置き直す。器は補間中に毎フレーム
                    // 変わるため、時間の猶予を立て直すと反対向きの指操作まで捨て続けてしまう。
                    // **末尾で境界そのものが動いた回も同じ**（仕様 5.1 章 第 5 版）。文字サイズなどの更新で、
                    // 器はそのままでも境界だけが下がることがあり、
                    // 末尾で引き伸ばされている最中なら指が止まっていても挟んだ位置が一緒に下がる。
                    // それを「上へ送った」と読むと操作帯が勝手に戻るので、ここで基準を置き直す。
                    let boundaryMoved = LyricsScrollProbe.boundaryMoved(from: old, to: new)
                    let containerChanged = old.containerSize != new.containerSize
                    hasScrollableRange = new.maximumOffset > 0
                    let canJudgeInertia = isJudgingScroll && !isInteractingScroll && programmaticScroll == nil
                    if let hidden = controlsScroll.observeOffset(
                        Double(new.judgedOffset), isDecelerating: canJudgeInertia,
                        layoutChanged: boundaryMoved || containerChanged,
                        allowTopShortcut: hasScrollableRange && new.judgedOffset <= Self.topSlack)
                    {
                        setControlsHidden(hidden)
                    }
                }
                // 1% は部分的に見えた行も復帰候補にする Musicfin の暫定値で、Apple の実測値ではない。
                .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { visible in
                    visibleLineIndices = Set(visible)
                    reacquireFollowIfVisible(proxy: proxy)
                }
                // **`isFollowing` が止めるのはスクロールだけ**（仕様 5.2 章）。過去の歌詞を手で読んでいる間も
                // 現在行の算出と強調は続くので、ここの `guard` は `scroll` の手前にしか置かない。
                .onChange(of: position) { previous, current in
                    let previousIndex = activeIndex(at: previous)
                    guard hasAligned, isSynced else { return }
                    guard isFollowing else {
                        reacquireFollowIfVisible(proxy: proxy)
                        return
                    }
                    guard previousIndex != active else { return }
                    let roll =
                        !isSeeking && Date.now.timeIntervalSinceReferenceDate >= directAlignmentUntil
                        && LyricsRollMotion.shouldRoll(
                            from: previousIndex, to: active, previousPosition: previous, position: current,
                            isPlaying: player.isPlaying, reduceMotion: reduceMotion)
                    scroll(to: active ?? Self.introID, proxy: proxy, roll: roll)
                }
                .onChange(of: isSeeking) { _, seeking in
                    if seeking { cancelRoll() }
                }
                .onChange(of: reduceMotion) { _, reduced in
                    if reduced { cancelRoll() }
                }
                .onChange(of: lyricSize) { _, _ in cancelRoll() }
                // 初回だけは上部の切り替えが終わってから合わせる（仕様 5.1 章）。
                // 遷移中に動かすと、対応付けた画像と本文が別の速さで流れて二重に見える。
                .onChange(of: isSettled, initial: true) { _, settled in
                    guard settled, !hasAligned else { return }
                    hasAligned = true
                    // 遷移中に触れていた場合、先に届いた idle / 可視通知は初回合わせ待ちで保留される。
                    // 曲が停止中でも、この待ちが開いた時点で可視行から追従を取り直せるようにする。
                    guard isFollowing else {
                        reacquireFollowIfVisible(proxy: proxy)
                        return
                    }
                    guard let active else { return }
                    scroll(to: active, proxy: proxy)
                }
                // 画面外へ出た本文の待ちは残さない。曲を跨いだ移動は `load()` 側で断つ。
                .onDisappear {
                    cancelRoll()
                    programmaticScroll?.cancel()
                    programmaticScroll = nil
                }
            }
        }
    }

    private func lyricsContent(active: Int?, viewportHeight: CGFloat, at time: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 操作帯の伸縮中に遅延配置の見積もりが変わると、位置補正が指の送りを押し戻す。
            // 全行の高さを先に確定し、同じ接触のまま本文を送れるようにする。
            VStack(alignment: .leading, spacing: lyricSpacing) {
                // 時刻の無い歌詞では現在行が決まらない。全行を強調して「どれも現在行」に見せるより、
                // 追従できない歌詞だと先に断る（仕様 5.2 章）。時刻は作らない。
                if !isSynced {
                    Text("この歌詞には時間情報がありません。再生に合わせた自動追従は行いません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                }
                if isSynced, (lines.compactMap(\.startSeconds).min() ?? 0) > 0 {
                    // 歌い出しで器まで外すと本文が縮み、追従のスクロールと位置変更が重なる。
                    // 丸だけを消し、高さを保ったまま現在行へ送る。
                    introIndicator
                        .opacity(active == nil ? 1 : 0)
                        .accessibilityHidden(active != nil)
                        .id(Self.introID)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Group {
                        if let start = line.startSeconds {
                            Button {
                                // 行タップは「ここへ飛ぶ」意思表示なので、追従を切ったままにしない。
                                // タップでも指は触れるので `.tracking` で `isFollowing` が落ちており、
                                // ここで戻さないと、画面外の飛び先は手動閲覧の保護に阻まれて位置が合わなくなる。
                                cancelRoll()
                                directAlignmentUntil = Date.now.timeIntervalSinceReferenceDate + 0.5
                                isFollowing = true
                                player.seek(to: start)
                            } label: {
                                lineText(line, index: index, activeIndex: active)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("この行の再生位置へ移動")
                            .accessibilityAddTraits(index == active ? .isSelected : [])
                        } else {
                            // 時刻が無ければ飛び先も無いので、押せる行にしない（仕様 5.2 章）。
                            lineText(line, index: index, activeIndex: active)
                        }
                    }
                    .offset(y: CGFloat(scrollLag?.compensation(for: index, at: time, reduceMotion: reduceMotion) ?? 0))
                    .id(index)
                    .accessibilityIdentifier("lyrics.line.\(index)")
                }
            }
            .scrollTargetLayout()
            // 先頭行にも同じ 0.15 の位置を渡せるだけのスクロール可能な余白を作る。
            // 外側へ padding すると本文の見える上端まで下がるので、内容側だけを延ばす。
            .padding(.top, max(0, viewportHeight - bottomExtension) * Self.activeLineTopRatio)
            // 下の 24 pt は最終行が操作帯へ貼り付かないための余白なので残す。
            .padding(.bottom, 24)
            // 同じ画面の小アートワークや曲名と同じ左右 32 pt に載せる（仕様 5 章）。外側の 24 pt との差。
            .padding(.horizontal, 8)
        }
    }

    /// 壁時計だけの繰り返しでは停止やシークとずれるため、前奏は曲の時計に同期させる。
    private var introIndicator: some View {
        LyricsPreludeIndicator(
            position: player.currentTime,
            lyricStart: lines.compactMap(\.startSeconds).min() ?? 0,
            isAdvancing: player.isPlaying && !player.isBuffering,
            lyricSize: lyricSize)
    }

    private func setControlsHidden(_ hidden: Bool) {
        guard controlsHidden != hidden else { return }
        controlsHidden = hidden
        onControlsVisibilityChange(hidden)
    }

    /// 時間だけで画面外の現在行へ戻さず、読む場所に現在行が入った事実から追従を取り直す。
    private func reacquireFollowIfVisible(proxy: ScrollViewProxy) {
        let active = activeIndex(at: player.currentTime)
        guard hasAligned, !isFollowing,
            LyricsFollowPolicy.canReacquire(
                activeIndex: active, visibleIndices: visibleLineIndices, introID: Self.introID, isSynced: isSynced,
                isUserScrolling: scrollPhase != .idle || controlsScroll.isDragging)
        else { return }
        isFollowing = true
        scroll(to: active ?? Self.introID, proxy: proxy)
    }

    /// 全行で同じ大きさ・同じウェイトにする。現在行だけ大きくすると行高が変わり、
    /// 追従のたびに前後の行が動いて読む位置を見失う（ファイル冒頭の方針・仕様 5.2 章）。
    /// 濃淡は `.primary` / `.secondary` のまま。**濃さの係数は測れていないので足さない**が、
    /// ぼかしだけは参照録画から逆算できたので入れてある（仕様 5.2 章）。
    /// 段内に `lineSpacing` を足さないのも同じ理由で、項目間隔だけで間を作る。
    private func lineText(_ line: LyricLine, index: Int, activeIndex: Int?) -> some View {
        let active = index == activeIndex
        return Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: lyricSize, weight: .bold))
            .foregroundStyle(active ? .primary : .secondary)
            // ぼかすのは**文字だけ**。`.frame` と `.contentShape` より前に掛けることで、
            // 押せる範囲と読み上げの範囲はぼかしても動かない。
            .blur(radius: blurRadius(index: index, activeIndex: activeIndex))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // 44 pt はタップ領域の下限。文字が大きくなれば行の高さはそちらに従って伸びる。
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
    }

    /// ぼかすのは**自動で追い掛けている間の、現在行以外だけ**（仕様 5.2 章）。
    /// 手で送っている間に外すのは、そのとき読みたいのは現在行ではなく指が止めた場所だから。
    /// 前奏中は丸を現在の位置として示し、これから歌う行を同じぼかしで後ろへ退かせる。
    private func blurRadius(index: Int, activeIndex: Int?) -> CGFloat {
        lyricBlur
            * LyricsFollowPolicy.blurMultiplier(
                index: index, activeIndex: activeIndex, isSynced: isSynced, isFollowing: isFollowing,
                reduceTransparency: reduceTransparency)
    }

    /// 位置合わせは**すべてここを通す**（仕様 5.1 章 第 4 版）。初回の位置合わせ・現在行の追従・
    /// 可視行での追従復帰・行タップ後の合わせは、どれも利用者が送ったのではない移動なので、
    /// 「プログラムが動かしている間は判定しない」を各呼び出し元ではなくこの 1 か所で立てる。
    private func scroll(to index: Int, proxy: ScrollViewProxy, roll: Bool = false) {
        if roll {
            let now = Date.now.timeIntervalSinceReferenceDate
            if scrollLag != nil {
                scrollLag?.advance(to: index, at: now)
            } else {
                scrollLag = LyricsRollMotion(anchorIndex: index, offset: Double(currentScrollOffset), time: now)
            }
            // phase が変わらない短い送りでも待ちを残さない。通常は idle の後、最後の行が追いついたら解く。
            finishRoll(after: .seconds(1))
        } else {
            cancelRoll()
        }
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
            if index == Self.introID {
                // 前奏行の手前にある上余白も含めて元の位置へ戻すため、行IDではなく端へ合わせる。
                introPosition.scrollTo(edge: .top)
            } else {
                introPosition.isPositionedByUser = true
                proxy.scrollTo(index, anchor: Self.activeLineAnchor)
            }
        }
    }

    private func finishRoll(after delay: Duration) {
        guard scrollLag != nil else { return }
        rollCompletion?.cancel()
        rollCompletion = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            scrollLag = nil
            rollCompletion = nil
        }
    }

    private func cancelRoll() {
        rollCompletion?.cancel()
        rollCompletion = nil
        scrollLag = nil
    }

    private func load() async {
        cancelRoll()
        directAlignmentUntil = 0
        isLoading = true
        isFollowing = true
        hasAligned = false
        // 前の曲の移動を残すと、新しい歌詞を読み込んだ直後に飛ばされる。
        programmaticScroll?.cancel()
        programmaticScroll = nil
        isJudgingScroll = false
        isInteractingScroll = false
        controlsScroll = LyricsControlsScroll()
        scrollPhase = .idle
        visibleLineIndices = []
        hasScrollableRange = true
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

private struct LyricsPreludeIndicator: View {
    let position: TimeInterval
    let lyricStart: TimeInterval
    let isAdvancing: Bool
    let lyricSize: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var sample: LyricsPreludeClock

    init(position: TimeInterval, lyricStart: TimeInterval, isAdvancing: Bool, lyricSize: Double) {
        self.position = position
        self.lyricStart = lyricStart
        self.isAdvancing = isAdvancing
        self.lyricSize = lyricSize
        _sample = State(initialValue: LyricsPreludeClock(position: position, sampledAt: .now))
    }

    var body: some View {
        let scale = lyricSize / 32
        let advancing = isAdvancing && scenePhase == .active && position < lyricStart
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !advancing || reduceMotion)) { context in
            let time = advancing ? sample.presentationPosition(at: context.date, advancing: true) : position
            let motion = LyricsPreludeMotion.at(position: time, lyricStart: lyricStart, reduceMotion: reduceMotion)
            HStack(spacing: 8.3 * scale) {
                ForEach(0..<3) { index in
                    Circle().frame(width: 15 * scale, height: 15 * scale)
                        .opacity(motion.dotOpacities[index])
                }
            }
            .foregroundStyle(.primary)
            .scaleEffect(CGFloat(motion.scale), anchor: .leading)
            .opacity(motion.opacity)
            // 拡縮が行高や後続の歌詞を動かさないよう、前奏の器は参照と同じ高さに保つ。
            .frame(height: 70 * scale)
            .offset(x: -4 * scale)
        }
        .onChange(of: position, initial: true) { _, value in
            sample = LyricsPreludeClock(position: value, sampledAt: .now)
        }
        .onChange(of: isAdvancing) { _, _ in
            sample = LyricsPreludeClock(position: position, sampledAt: .now)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("前奏")
        .accessibilityIdentifier("lyrics.intro-placeholder")
        .accessibilityAddTraits(.isSelected)
        .allowsHitTesting(false)
    }
}

#Preview {
    LyricsView(track: MediaItem(id: "preview-track", name: "夜の散歩", type: .audio))
        .environment(AuthStore())
        .environment(PlaybackEngine())
        .frame(height: 320)
        .padding()
}
