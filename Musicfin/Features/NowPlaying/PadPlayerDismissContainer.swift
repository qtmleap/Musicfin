import SwiftUI
import UIKit

/// iPad のフルプレイヤー全体を指に追従させて閉じる容器。
/// 動く中身の内側で `DragGesture` を測ると、中身が動くたびに translation が変わって
/// 追従が自分自身へ戻ってしまう。そのため座標空間は**動かない外側**に置き、中身だけを `offset` する。
/// 中身の不透明な背景ごと動かすので、下に見えるのは提示元の画面（`RootView` 側で提示背景を透明にしてある）。
struct PadPlayerDismissContainer<Content: View>: View {
    /// 指を置いた位置（外側の座標空間）と容器の大きさから、閉じる操作を始めてよいかを返す。
    let allowsStart: (CGPoint, CGSize) -> Bool
    /// UIKit のシークは SwiftUI の `onEnded` より先に終わりうるので、現在値と接触中の履歴の両方で見る。
    let isScrubbing: Bool
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var space: String { "padPlayerDismissOuter" }
    /// 既存の閉じる判定。速度や進捗の閾値は足さない。
    private static var closeDistance: CGFloat { 60 }

    private enum Phase { case idle, following, returning, closing }

    /// 1 回の接触ぶんの記録。開始時の判定は途中で変わった領域やモードで読み直さない。
    private struct Contact {
        let id = UUID()
        let isEligible: Bool
        /// 最初の更新で縦優勢だったか。横に始まった指は後から縦へ流れても追従しない。
        let isDownward: Bool
        var baseOffset: CGFloat = 0
        var sawScrub = false
        /// 消滅・寸法変更・シーク成立で無効にした接触。指が離れるまで何もしない。
        var isInvalid = false

        var isUsable: Bool { isEligible && isDownward && !sawScrub && !isInvalid }
    }

    /// アニメーション中の実際の位置。復帰途中で触り直しても、目標値の 0 へ飛ばさない。
    @State private var renderedPosition = PadPlayerRenderedPosition()
    @State private var offset: CGFloat = 0
    @State private var phase = Phase.idle
    @State private var contact: Contact?
    @State private var size = CGSize.zero
    @State private var topCornerRadius: CGFloat = 0
    /// 戻し・閉じるの完了通知が、後から始まった別の動きを上書きしないための世代。
    @State private var generation = 0
    /// 取り消しでも必ず戻る `GestureState`。`onEnded` が呼ばれない経路を拾う。
    @GestureState private var isTracking = false

    var body: some View {
        ZStack {
            PadPlayerRenderedOffset(
                y: offset,
                position: renderedPosition,
                topCornerRadius: topCornerRadius,
                // 静止中は角を付けない。追従・復帰・終了の間は途切れさせず丸めたままにする。
                isRounded: phase != .idle
            ) {
                content()
                    // スクロールを止めるのは、閉じる追従が実際に始まった接触だけ。右本文などは触らない。
                    .scrollDisabled(phase == .following)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            PadPlayerCornerResolver { topCornerRadius = $0 }
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .coordinateSpace(.named(Self.space))
        // 地は safe area の外まで描くため、送り出す距離にも上下の余白を含める。
        .onGeometryChange(for: CGSize.self) { geometry in
            CGSize(
                width: geometry.size.width,
                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            )
        } action: { newSize in
            if size != .zero, newSize != size {
                if phase == .closing {
                    // 終了を確定した後の回転では、古い距離の完了を待たず終了の意思を維持する。
                    generation += 1
                    closeWithoutAnimation()
                } else {
                    resetPresentation()
                }
            }
            size = newSize
        }
        .simultaneousGesture(dismissGesture)
        .onChange(of: isTracking) { _, tracking in
            guard !tracking, let id = contact?.id else { return }
            // `onEnded` と前後して届くことがあるので、一拍置いて同じ接触が残っているときだけ取り消しとみなす。
            Task { @MainActor in
                await Task.yield()
                guard contact?.id == id else { return }
                contact = nil
                if phase == .following { settleBack() }
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            guard scrubbing, contact != nil else { return }
            contact?.sawScrub = true
            if phase == .following { settleBack() }
        }
        .onDisappear { resetPresentation() }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(Self.space))
            .updating($isTracking) { _, tracking, _ in tracking = true }
            .onChanged { value in
                if contact == nil {
                    let base = phase == .returning ? renderedPosition.y : offset
                    let start = CGPoint(x: value.startLocation.x, y: value.startLocation.y - base)
                    let eligible = (phase == .idle || phase == .returning) && allowsStart(start, size)
                    let newContact = Contact(
                        isEligible: eligible,
                        isDownward: value.translation.height > abs(value.translation.width),
                        baseOffset: base
                    )
                    if newContact.isUsable { generation += 1 }
                    contact = newContact
                }
                guard var current = contact else { return }
                if isScrubbing { current.sawScrub = true }
                contact = current
                // 成立済みのシークが後から見つかったら、動かした分を戻して以後は閉じない。
                guard current.isUsable else {
                    if phase == .following { settleBack() }
                    return
                }
                phase = .following
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { offset = max(0, current.baseOffset + value.translation.height) }
            }
            .onEnded { value in
                defer { contact = nil }
                guard let current = contact else { return }
                let shouldClose =
                    current.isUsable && !current.sawScrub && !isScrubbing
                    && value.translation.height > Self.closeDistance
                    && value.translation.height > abs(value.translation.width)
                if shouldClose {
                    finishClose()
                } else if phase == .following {
                    settleBack()
                }
            }
    }

    /// 寸法変更や消滅では、古い終了通知を無効にして位置も即座に戻す。
    private func resetPresentation() {
        generation += 1
        if isTracking {
            if contact != nil {
                contact?.isInvalid = true
            } else {
                contact = Contact(isEligible: false, isDownward: false, isInvalid: true)
            }
        } else {
            contact = nil
        }
        phase = .idle
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { offset = 0 }
    }

    /// 短い引きや取り消しは 0 へ戻す。弾みは付けず、視差を減らす設定ではさらに短くする。
    private func settleBack() {
        guard phase != .closing else { return }
        generation += 1
        let token = generation
        phase = .returning
        let animation: Animation =
            reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3, extraBounce: 0)
        withAnimation(animation) {
            offset = 0
        } completion: {
            guard generation == token, phase == .returning else { return }
            phase = .idle
        }
    }

    /// 現在位置から画面の下端まで滑らせ、その後で提示元の状態を落とす。
    /// 落とす側は標準の閉じるアニメーションを重ねないよう、アニメーション無しの更新で呼ぶ。
    private func finishClose() {
        guard phase != .closing else { return }
        phase = .closing
        generation += 1
        let token = generation
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.28)
        withAnimation(animation) {
            offset = max(size.height, offset)
        } completion: {
            guard generation == token, phase == .closing else { return }
            closeWithoutAnimation()
        }
    }

    private func closeWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { close() }
    }
}

/// 補間値を SwiftUI の状態へ書き戻すと再描画が循環するため、読み取り用の箱だけに記録する。
private final class PadPlayerRenderedPosition {
    var y: CGFloat = 0
}

/// 目標の offset ではなく毎フレームの補間値を残し、触り直したときの出発点にする。
private struct PadPlayerRenderedOffset<Content: View>: View, Animatable {
    var y: CGFloat
    let position: PadPlayerRenderedPosition
    let topCornerRadius: CGFloat
    let isRounded: Bool
    @ViewBuilder let content: () -> Content

    nonisolated var animatableData: CGFloat {
        get { y }
        set { y = newValue }
    }

    var body: some View {
        position.y = y
        return
            GeometryReader { geometry in
                content()
                    // 余白は本文へ足さず、切り抜きの輪郭だけ背景が描く safe area まで広げる。
                    .clipShape(
                        PadPlayerClipShape(
                            radius: isRounded ? topCornerRadius : 0,
                            insets: geometry.safeAreaInsets
                        )
                    )
            }
            // 角の有無の切り替えは補間しない。
            .animation(nil, value: isRounded)
            .offset(y: y)
    }
}

nonisolated private struct PadPlayerClipShape: Shape {
    var radius: CGFloat
    var insets: EdgeInsets

    func path(in rect: CGRect) -> Path {
        let expanded = CGRect(
            x: rect.minX - insets.leading,
            y: rect.minY - insets.top,
            width: rect.width + insets.leading + insets.trailing,
            height: rect.height + insets.top + insets.bottom
        )
        return UnevenRoundedRectangle(
            topLeadingRadius: radius, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: radius, style: .continuous
        ).path(in: expanded)
    }
}

/// 動くビュー内では同心角丸が画面端から離れて 0 になるため、静止した全窓で解決する。
private struct PadPlayerCornerResolver: UIViewRepresentable {
    let onResolve: (CGFloat) -> Void

    func makeUIView(context: Context) -> PadPlayerCornerResolverView {
        PadPlayerCornerResolverView()
    }

    func updateUIView(_ view: PadPlayerCornerResolverView, context: Context) {
        view.onResolve = onResolve
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: PadPlayerCornerResolverView, coordinator: ()) {
        view.generation += 1
        view.onResolve = nil
    }
}

private final class PadPlayerCornerResolverView: UIView {
    var onResolve: ((CGFloat) -> Void)?
    var generation = 0
    private var lastRadius: CGFloat?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        cornerConfiguration = .uniformTopRadius(.containerConcentric(), bottomLeftRadius: 0, bottomRightRadius: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        generation += 1
        lastRadius = nil
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, !bounds.isEmpty else { return }
        // 設定直後は未解決になりうるので、公開 API がレイアウト後に返した有限値だけを使う。
        let radius = effectiveRadius(corner: [.topLeft, .topRight])
        guard radius.isFinite, radius >= 0, lastRadius != radius else { return }
        lastRadius = radius
        let token = generation
        // SwiftUI の描画中に State を書かず、撤去や次のレイアウトに追い越された通知も捨てる。
        Task { @MainActor [weak self] in
            guard let self, generation == token, window != nil, lastRadius == radius else { return }
            onResolve?(radius)
        }
    }
}
