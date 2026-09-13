import SwiftUI
import UIKit

// MARK: - SwiftUI からの入口

extension View {
    /// iPhone のフルプレイヤーを UIKit のカスタム提示で出す（仕様 4.1.1 章）。
    /// sheet の `.large` detent が上端に空ける 62 pt を塞ぐのが目的で、上角の丸みと下スワイプの
    /// 指追従はこの経路が自分で持つ。iPad の中央 sheet はこれを通さず `.sheet` のままにする。
    func playerPresentation(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        background(PlayerPresentationBridge(isPresented: isPresented, content: { AnyView(content()) }))
    }
}

/// 提示の引き金だけを持つ、何も描かないビュー。SwiftUI から提示元の `UIViewController` を得る経路が
/// これしか無いので、表示物ではなく橋渡しとして置く。
private struct PlayerPresentationBridge: UIViewRepresentable {
    let isPresented: Binding<Bool>
    let content: () -> AnyView

    func makeCoordinator() -> PlayerPresentationCoordinator { PlayerPresentationCoordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        // 本文の背後に敷かれるので、当たり判定を持つとタブやミニプレイヤーの操作を吸ってしまう。
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(anchor: uiView, isPresented: isPresented, content: content())
    }

    /// 橋渡しそのものが捨てられたときの後始末。body の再評価では呼ばれないが、`RootView` の identity が
    /// 替わったり画面ツリーから外れたときは呼ばれる。ここで畳まないと**UIKit 側のプレイヤーだけが残り、
    /// 終了させる担い手を失う**。
    static func dismantleUIView(_ uiView: UIView, coordinator: PlayerPresentationCoordinator) {
        coordinator.tearDown()
    }
}

// MARK: - 提示と終了の担い手

/// 提示・終了・指追従をまとめて持つ。提示中の controller と進行中の遷移は SwiftUI の更新で
/// 作り直されてはいけないので、`Coordinator` 側に置く。
private final class PlayerPresentationCoordinator: NSObject {
    /// 閉じると決める引きの割合と速さ。`.large` の sheet に合わせた操作上の決定値で、
    /// Apple Music の実測値ではない。実機で触ってから見直す。
    private static let dismissProgress = 0.33
    private static let dismissVelocity = 800.0

    /// 提示の段階。**遷移中は要求に従わず、終わってから最新の要求を見直す**（仕様 4.1.1 章）。
    /// 進行中の遷移へ重ねて `dismiss` を投げると、その遷移が取り消されたときに表示と
    /// `isPresented` が食い違い、以後 SwiftUI からの更新が来ないまま戻せなくなる。
    private enum Stage { case idle, presenting, presented, dismissing }

    private var stage: Stage = .idle
    /// 最新の表示要求。遷移の完了時にこれを見て、必要なら続けて提示・終了する。
    private var wantsPresented = false
    private var isPresented: Binding<Bool> = .constant(false)
    private weak var anchor: UIView?
    private var content: AnyView?
    private var hosting: UIHostingController<AnyView>?
    private let transitioning = PlayerTransitioningDelegate()
    private var interaction: UIPercentDrivenInteractiveTransition?

    override init() {
        super.init()
        transitioning.onPresentEnded = { [weak self] completed in
            self?.presentEnded(completed: completed)
        }
        transitioning.onDismissEnded = { [weak self] completed in
            self?.dismissEnded(completed: completed)
        }
    }

    func update(anchor: UIView, isPresented: Binding<Bool>, content: AnyView) {
        self.isPresented = isPresented
        self.anchor = anchor
        self.content = content
        wantsPresented = isPresented.wrappedValue
        hosting?.rootView = content
        applyDesiredStage()
    }

    /// 段階と最新の要求を突き合わせる。遷移中は何もせず、`presentEnded` / `dismissEnded` から呼び直す。
    private func applyDesiredStage() {
        switch stage {
        case .presenting, .dismissing:
            return
        case .presented:
            if !wantsPresented { beginDismiss() }
        case .idle:
            if wantsPresented { present() }
        }
    }

    private func present() {
        // 窓に載る前は提示できない。ここへ来るのはミニプレイヤーを押したあとなので、待ち合わせは要らない。
        guard let content, let anchor, let presenter = Self.presenter(for: anchor) else { return }
        // 提示先が遷移の最中だと `present` は成立しない。**成立しなかったものを「表示済み」として
        // 覚えると、次の更新が `rootView` の差し替えへ入って二度と提示されない**。
        guard presenter.transitionCoordinator == nil, !presenter.isBeingPresented, !presenter.isBeingDismissed
        else { return }

        let controller = UIHostingController(rootView: content)
        controller.modalPresentationStyle = .custom
        controller.transitioningDelegate = transitioning
        // 地は SwiftUI 側の帯が safe area を無視して敷くので、UIKit の地は透かす。
        // 角丸は**画面の角と同じ丸みで持ち続ける**。`containerConcentric` は容器（＝窓）の角から
        // 決まり、iPhone 17 Pro では 62 pt に解決される（Simulator 実測）。下へずらしても値が変わらないので、
        // 上端が画面の角から連続して剥がれて見える。丸みをドラッグ量で動かしていたときは、
        // 動き始めた瞬間の丸みが画面の角と合わず段差に見えていた（実機報告 #2）。
        // 丸みの曲線は `cornerConfiguration` 側が持つので、`cornerCurve` を別に指定しない。
        controller.view.backgroundColor = .clear
        controller.view.layer.masksToBounds = true
        controller.view.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
        // `safeAreaRegions` は既定の `.all` のまま。上端を塞ぐのは提示枠の仕事であって、
        // 本文の safe area を削る話ではない（仕様 4.1.1 章）。`additionalSafeAreaInsets` も触らない。

        let pan = PlayerDismissPan(target: self, action: #selector(handleDismissPan))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        controller.view.addGestureRecognizer(pan)

        hosting = controller
        stage = .presenting
        presenter.present(controller, animated: true)
        // 提示が成立すれば関係はこの時点で立っている。立っていなければ覚えたものを捨て、次の更新でやり直す。
        guard controller.presentingViewController != nil else {
            hosting = nil
            stage = .idle
            return
        }
    }

    /// 画面側（VoiceOver のエスケープ）や再生の終了から閉じる。指追従ではないので `interaction` は渡さない。
    private func beginDismiss() {
        guard stage == .presented, let hosting, hosting.presentingViewController != nil else { return }
        stage = .dismissing
        hosting.dismiss(animated: true)
    }

    private func presentEnded(completed: Bool) {
        if completed {
            stage = .presented
        } else {
            stage = .idle
            hosting = nil
        }
        applyDesiredStage()
    }

    private func dismissEnded(completed: Bool) {
        interaction = nil
        transitioning.interaction = nil
        if completed {
            hosting = nil
            stage = .idle
            // 指で閉じきった場合はこれが最新の要求になる。先に落としておかないと、
            // この直後の見直しで再提示してしまう。
            wantsPresented = false
            if isPresented.wrappedValue { isPresented.wrappedValue = false }
        } else {
            // 取り消されたら提示は続くので、SwiftUI 側の状態も戻さない（仕様 4.1.1 章）。
            stage = .presented
        }
        // 取り消しの最中に来ていた「閉じる」要求は、ここで初めて処理できる。
        applyDesiredStage()
    }

    /// 橋渡しが捨てられたときに、所有している提示だけを畳む。SwiftUI 側へ書き戻す相手はもう居ないので、
    /// 呼び出しを外してから外す。進行中の終了は最後まで進めたほうが確実なので、追従だけ畳んで任せる。
    func tearDown() {
        wantsPresented = false
        isPresented = .constant(false)
        anchor = nil
        content = nil
        transitioning.onPresentEnded = nil
        transitioning.onDismissEnded = nil
        if stage == .dismissing {
            interaction?.finish()
        } else if let hosting, hosting.presentingViewController != nil {
            hosting.dismiss(animated: false)
        }
        interaction = nil
        transitioning.interaction = nil
        hosting = nil
        stage = .idle
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        guard let view = pan.view else { return }
        let height = max(view.bounds.height, 1)
        let progress = min(max(pan.translation(in: view).y / height, 0), 1)
        switch pan.state {
        case .began:
            beginInteractiveDismiss()
        case .changed:
            interaction?.update(progress)
        case .ended:
            // 3 分の 1 まで引いたか、下向きに十分速ければ閉じる。どちらでもなければ元へ戻す。
            let velocity = pan.velocity(in: view).y
            let isFlicked = velocity > Self.dismissVelocity
            if progress > Self.dismissProgress || isFlicked {
                interaction?.finish()
            } else {
                // 戻りだけは離した瞬間の速さを引き継いだばねに差し替える。既定の完了曲線は
                // 残り時間が引いた割合に比例するので、浅く引いて離すとほぼ瞬間で戻ってしまう。
                transitioning.prepareCancel(velocity: velocity, distance: progress * height)
                interaction?.cancel()
            }
            interaction = nil
        case .cancelled, .failed:
            interaction?.cancel()
            interaction = nil
        default:
            break
        }
    }

    private func beginInteractiveDismiss() {
        // 復帰アニメーションの最中はまだ `.dismissing` なので、ここで再入が止まる。
        guard stage == .presented, let hosting, interaction == nil else { return }
        stage = .dismissing
        let interaction = UIPercentDrivenInteractiveTransition()
        // 追従中は `update(_:)` が進行を決め、指を離したあとの残りだけシステムの曲線に任せる。
        interaction.wantsInteractiveStart = true
        interaction.completionCurve = .easeOut
        self.interaction = interaction
        transitioning.interaction = interaction
        hosting.dismiss(animated: true)
    }

    /// 提示元。応答の連なりから最も近い controller を取り、その上に何か出ていれば更に上へ登る。
    /// 窓の根から出さないのは、設定などが先に出ているときに「既に提示中」で失敗するため。
    private static func presenter(for view: UIView) -> UIViewController? {
        var controller = sequence(first: view as UIResponder, next: \.next)
            .compactMap { $0 as? UIViewController }
            .first
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return view.window == nil ? nil : controller
    }
}

/// 終了 pan の調停。同時認識は既定の「しない」に任せ、ここでは失敗の依存だけを決める。
extension PlayerPresentationCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? PlayerDismissPan, let view = pan.view else { return false }
        // 出入りの最中は終了を始めさせない。始めさせると進行中の遷移へ 2 つ目の終了が重なる。
        guard stage == .presented else { return false }
        pan.recordTouchStartIfNeeded(in: view)
        let translation = pan.translation(in: view)
        // 下向きで縦が優勢な動きだけを終了に使う。横と上向きはシークと本文へ渡す。
        guard translation.y > 0, translation.y > abs(translation.x) else { return false }
        // 本文の中なら、接触を始めた時点で先頭にいた場合だけ終了にする。
        // 途中から始めたスクロールは先頭へ届いても終了へ取り替えない（仕様 4.1.1 章）。
        return pan.trackedScrollView == nil || pan.startedAtTop
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        // シークが成立すれば終了は失敗し、シークが失敗してから終了が動く。
        // `isEnabled` の往復では認識開始の競争を防げないので、依存はこの 1 方向だけで作る（仕様 4.2 章）。
        other is SeekGestureRecognizer
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer is PlayerDismissPan else { return false }
        // 対象は触れた本文の scroll pan だけ。UIKit がこの問い合わせを出すのは同じ接触を追っている
        // 認識器の組に限られるので、`UIScrollView` 自身の pan かどうかで足りる。
        guard let scrollView = other.view as? UIScrollView else { return false }
        return other === scrollView.panGestureRecognizer
    }
}

// MARK: - 終了 pan

/// 終了 pan。接触が始まった時点の内側 `UIScrollView` と、その先頭にいたかを覚える（仕様 4.1.1 章）。
/// 本文先頭からの下向きだけを終了にし、途中から始めたスクロールはその接触が終わるまでスクロールに固定する。
private final class PlayerDismissPan: UIPanGestureRecognizer {
    /// 先頭判定の許容。`adjustedContentInset` は小数になり、弾みの戻りも残るので厳密な等号では取り落とす。
    private static let topEpsilon: CGFloat = 0.5

    private var hasRecorded = false
    private(set) var trackedScrollView: UIScrollView?
    private(set) var startedAtTop = true

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        recordTouchStartIfNeeded(in: view)
    }

    /// 最初の 1 回だけ覚える。UIKit が失敗の依存を問い合わせる順は `touchesBegan` より前になり得るので
    /// 両方から呼べるようにし、2 本目の指で先頭状態を上書きしない。
    func recordTouchStartIfNeeded(in view: UIView?) {
        guard !hasRecorded, let view, numberOfTouches > 0 else { return }
        hasRecorded = true
        let scrollView = Self.enclosingScrollView(at: location(in: view), in: view)
        trackedScrollView = scrollView
        startedAtTop =
            scrollView.map { $0.contentOffset.y <= -$0.adjustedContentInset.top + Self.topEpsilon } ?? true
    }

    override func reset() {
        super.reset()
        hasRecorded = false
        trackedScrollView = nil
        startedAtTop = true
    }

    /// 触れた点の下にある最も内側の `UIScrollView`。歌詞・キューの本文とアートワーク状態の外側がこれに当たる。
    private static func enclosingScrollView(at location: CGPoint, in view: UIView) -> UIScrollView? {
        var candidate = view.hitTest(location, with: nil)
        while let current = candidate, current !== view {
            if let scrollView = current as? UIScrollView { return scrollView }
            candidate = current.superview
        }
        return nil
    }
}

// MARK: - 提示枠

/// 提示枠を容器いっぱいにして、`.large` detent が空けていた上端 62 pt を塞ぐ（仕様 4.1.1 章）。
private final class PlayerPresentationController: UIPresentationController {
    override var frameOfPresentedViewInContainerView: CGRect {
        containerView?.bounds ?? super.frameOfPresentedViewInContainerView
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        // 遷移中もここは呼ばれる。移動はアニメーターが transform で持っているので、
        // 通常のレイアウトのときだけ枠を書き直して上書きを避ける。
        guard let presentedView, presentedView.transform.isIdentity else { return }
        presentedView.frame = frameOfPresentedViewInContainerView
    }
}

// MARK: - 遷移

private final class PlayerTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    /// 指追従のときだけ入る。`nil` のままなら出入りはアニメーターに任せきりになる。
    var interaction: UIPercentDrivenInteractiveTransition?
    var onPresentEnded: ((Bool) -> Void)?
    var onDismissEnded: ((Bool) -> Void)?
    /// 進行中の終了アニメーター。取り消しの戻りへ指の速さを渡すためだけに覚える。
    private weak var dismissAnimator: PlayerTransitionAnimator?

    /// 取り消しの戻りに使うばねを、離した瞬間の速さから作って渡す。
    func prepareCancel(velocity: CGFloat, distance: CGFloat) {
        dismissAnimator?.prepareCancel(velocity: velocity, distance: distance)
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        PlayerPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        PlayerTransitionAnimator(isPresenting: true, isInteractive: false, onEnded: onPresentEnded)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        let animator = PlayerTransitionAnimator(
            isPresenting: false,
            isInteractive: interaction != nil,
            onEnded: onDismissEnded
        )
        dismissAnimator = animator
        return animator
    }

    func interactionControllerForDismissal(
        using animator: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        interaction
    }
}

/// 指を離したあとの続きだけ、渡されたばねに差し替えるアニメーター。
/// `UIPercentDrivenInteractiveTransition` の `completionCurve` は cubic の 4 種しか取らないので、
/// **離した瞬間の速さをそこから持ち込めない。**UIKit が「残りを進めてくれ」と頼む窓口はこの 1 つなので、
/// ここで受け取ったばねに置き換える。`continuation` が無いときは頼まれたとおりに進める。
private final class PlayerContinuationAnimator: UIViewPropertyAnimator {
    /// 次の継続で使うばね。1 回使ったら捨てて、以降は既定の曲線に戻す。
    var continuation: UITimingCurveProvider?

    override func continueAnimation(
        withTimingParameters parameters: UITimingCurveProvider?,
        durationFactor: CGFloat
    ) {
        guard let continuation else {
            super.continueAnimation(withTimingParameters: parameters, durationFactor: durationFactor)
            return
        }
        self.continuation = nil
        // 0 はばね自身が決める時間で進める指定。ここで残り時間を掛けると、
        // 引いた割合に比例して縮むという直したかった性質がそのまま戻ってくる。
        super.continueAnimation(withTimingParameters: continuation, durationFactor: 0)
    }
}

/// 出入りのアニメーター。**動かすのは移動だけ**にする（仕様 4.1.1 章）。上角の丸みは提示ビューの
/// `cornerConfiguration` が画面の角と同じ値で持ち続けるので、遷移の側で触る対象ではなくなった。
/// UIKit は遷移中に同じインスタンスを返すことを要求するので、
/// `animateTransition(using:)` も `interruptibleAnimator(using:)` の結果をそのまま使う。
private final class PlayerTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// 取り消しの戻りに使うばねの応答時間と減衰比。**Musicfin の決定値で、Apple 実機の実測ではない。**
    /// 既定の完了曲線では戻りが `0.35 秒 × 引いた割合`＝浅い引きで 0.1 秒前後しかなく、
    /// 指を離した瞬間に消えるように見える（実機報告）。0.5 秒の応答なら 0.6 秒ほどで落ち着く。
    /// 0.85 は行き過ぎがかすかに出るだけの値で、戻り際に一度だけ息を継ぐように見える。
    private static let cancelResponse = 0.5
    private static let cancelDampingRatio = 0.85
    /// 引き継ぐ初速の上限（戻り距離の何倍／秒まで許すか）。行き過ぎの量はおよそ `初速 ÷ 固有角振動数`
    /// なので、`cancelResponse` から決まる 12.6 rad/s に対して 4 なら戻り距離の 3 割で頭を打つ。
    /// 浅く引いて速く離したときに、家の位置を大きく越えて跳ね上がるのを防ぐ。
    private static let cancelVelocityLimit: CGFloat = 4

    private let isPresenting: Bool
    private let isInteractive: Bool
    private let onEnded: ((Bool) -> Void)?
    private var animator: PlayerContinuationAnimator?

    init(isPresenting: Bool, isInteractive: Bool, onEnded: ((Bool) -> Void)?) {
        self.isPresenting = isPresenting
        self.isInteractive = isInteractive
        self.onEnded = onEnded
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0.45 : 0.35
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    /// 取り消しの戻りへ、離した瞬間の速さを持ち込んだばねを載せる。`cancel()` より前に呼ぶ。
    /// 上向き（画面座標で負）が戻る向きなので符号を反転させ、残りの距離で割って
    /// 「残りの何倍／秒」へ直す。`UISpringTimingParameters` の初速はこの単位で受ける。
    func prepareCancel(velocity: CGFloat, distance: CGFloat) {
        guard distance > 0 else { return }
        let normalized = -velocity / distance
        let limit = Self.cancelVelocityLimit
        let omega = 2 * CGFloat.pi / Self.cancelResponse
        animator?.continuation = UISpringTimingParameters(
            mass: 1,
            stiffness: omega * omega,
            damping: 2 * Self.cancelDampingRatio * omega,
            initialVelocity: CGVector(dx: 0, dy: min(max(normalized, -limit), limit))
        )
    }

    func interruptibleAnimator(
        using transitionContext: UIViewControllerContextTransitioning
    ) -> UIViewImplicitlyAnimating {
        if let animator { return animator }
        let animator = makeAnimator(using: transitionContext)
        self.animator = animator
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) {
        animator = nil
        onEnded?(transitionCompleted)
    }

    private func makeAnimator(using context: UIViewControllerContextTransitioning) -> PlayerContinuationAnimator {
        let container = context.containerView
        let key: UITransitionContextViewKey = isPresenting ? .to : .from
        let controllerKey: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        let presented = context.view(forKey: key)
        if let presented, let controller = context.viewController(forKey: controllerKey) {
            // 提示側で枠を決めるので、容器へ載せるのもここで済ませる。二重に足さないよう親だけ見る。
            if presented.superview == nil { container.addSubview(presented) }
            // **枠を書くのは提示のときだけ。**`finalFrame(for:)` は「遷移の終わりに窓から外れるビュー」
            // に対して `CGRectZero` を返してよいと SDK が明記しており、終了時の `.from` はまさにそれに
            // 当たる。入れば本文が 0 になり、取消経路は transform しか戻さないので寸法が復元されない。
            // iOS 26 の Simulator では実測で全面が返ってきたが、**返さないことが許されている以上**
            // 当てにはしない。終了は開いたときの枠のまま滑らせる。
            if isPresenting, presented.transform.isIdentity {
                presented.frame = context.finalFrame(for: controller)
            }
        }

        let offscreen = CGAffineTransform(translationX: 0, y: container.bounds.height)
        presented?.transform = isPresenting ? offscreen : .identity

        // 追従中は線形にして指と 1 対 1 で動かす。自動で出入りするときだけ弾みと減速を付ける。
        let timing: UITimingCurveProvider
        if isInteractive {
            timing = UICubicTimingParameters(animationCurve: .linear)
        } else if isPresenting {
            timing = UISpringTimingParameters(dampingRatio: 0.92)
        } else {
            timing = UICubicTimingParameters(animationCurve: .easeOut)
        }
        let animator = PlayerContinuationAnimator(
            duration: transitionDuration(using: context),
            timingParameters: timing
        )
        animator.addAnimations { [isPresenting] in
            presented?.transform = isPresenting ? .identity : offscreen
        }
        animator.addCompletion { [isPresenting] _ in
            // 取り消しでは始まりの側、完了では終わりの側へ明示的に置き直す。
            // 提示ビューと地は取り消しでも階層から外さない（仕様 4.1.1 章）。
            let isCancelled = context.transitionWasCancelled
            let staysOpen = isPresenting != isCancelled
            presented?.transform = staysOpen ? .identity : offscreen
            if !staysOpen, !isPresenting { presented?.removeFromSuperview() }
            context.completeTransition(!isCancelled)
        }
        return animator
    }
}
