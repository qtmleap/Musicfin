import SwiftUI
import UIKit

// MARK: - 提示の方式

/// フルプレイヤーの出入りの見せ方。**実機で見比べるための一時的な切り替え**で、
/// どちらが Apple Music に近いか決まったら片方だけ残して畳む（仕様 4.1.1 章）。
/// 保存先を `Core/Settings/` に足さず `@AppStorage` にしているのは、
/// 比較が済んだら消す設定を再生の設定と同じ器に混ぜないため。
nonisolated enum PlayerPresentationStyle: String, CaseIterable, Identifiable {
    /// 完成した寸法のまま下から上げる。現行の挙動で、これを既定にする。
    case slideUp
    /// ミニプレイヤーの矩形から画面全面へ、幅と高さの両方を広げる。
    case expandFromMiniPlayer
    /// UIKit が持つ標準 Zoom。自作の寸法補間と実機で見比べるために残す。
    case systemZoom

    /// `@AppStorage` のキー。設定画面と `RootView` の 2 か所から同じ値を読むので一つ置く。
    static let storageKey = "player.presentation.style"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slideUp: String(localized: "せり上がり（現行）")
        case .expandFromMiniPlayer: String(localized: "ミニプレイヤーから展開")
        case .systemZoom: String(localized: "システムZoom")
        }
    }
}

/// ミニプレイヤーの矩形（窓座標）を入れておく箱。**値ではなく参照で持つのが要点**である。
/// `CGRect` を `@State` に入れると、幾何の報告 → `RootView` の再評価 →
/// `tabViewBottomAccessory` の作り直し → 再計測、が閉じた輪になる。`.expanded` と `.inline` で
/// 矩形が違うので、往復し始めると収束しない。参照型へ書くだけなら SwiftUI は何も無効化しないので、
/// **幾何の報告が親の再レイアウトを誘発しない**。
/// 監視も等値比較も要らない（読むのは提示・終了の瞬間だけ）ので、`@Observable` は付けない。
final class PlayerSourceBox {
    /// ミニプレイヤーが出ていない間は `nil`。**帯が出ているかどうかの合図**として使う。
    /// 展開の幾何そのものには使わない。`MiniPlayerView` が測れるのはガラスの帯ではなく内側の行で、
    /// 左右が数 pt 内側に入ってしまうため（実測で帯 360 pt に対し行は 344 pt）。
    var rect: CGRect?
    /// 標準 Zoom は矩形ではなく実在する view を要求する。帯を SwiftUI から直接渡せないため、
    /// その内側いっぱいに敷いた透明 view を source として弱く覚える。
    weak var view: UIView?
    /// 「ミニプレイヤーから展開」で**撮影と計測の両方に使う帯の実体**。`view` とは別に持つ。
    /// ガラスと角丸を描いているのはその祖先なので、透明な `view` を撮っても何も写らない。
    weak var bandView: UIView?
}

/// `tabViewBottomAccessory` の SwiftUI 行を、標準 Zoom が要求する `UIView` へ橋渡しする。
/// 透明かつ非対話にして、ミニプレイヤーのボタンやスワイプを奪わない。
struct PlayerZoomSource: UIViewRepresentable {
    let source: PlayerSourceBox

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        source.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // SwiftUI の描画本体は representable 自身ではなく親の hosting view が持つ。次の run loop なら
        // アクセサリ内で寸法が確定しているので、同じ大きさを持つ最寄りの親を source にできる。
        DispatchQueue.main.async { [weak uiView, weak source] in
            guard let uiView, let source, uiView.window != nil else { return }
            source.bandView = Self.bandView(from: uiView)
            let size = uiView.bounds.size
            var candidate = uiView.superview
            while let view = candidate {
                let matchesWidth = abs(view.bounds.width - size.width) < 1
                let matchesHeight = abs(view.bounds.height - size.height) < 1
                if matchesWidth && matchesHeight {
                    source.view = view
                    return
                }
                candidate = view.superview
            }
        }
    }

    /// ガラスの帯を描いているビューを、**クラス名ではなく構造で**選ぶ。
    /// `tabViewBottomAccessory` の帯は UIKit 側の private なビューが持っており、外周を返す公開 API が無い。
    /// 実行時に祖先をたどると「透明な source と同寸法の並び → 帯そのもの → 画面幅の容器（タブバーを含む）」
    /// の順に並ぶので、**画面幅へ届く手前で最も外側の祖先**がちょうど帯だけを所有する。
    /// 画面幅で切ることで、タブバーごと隠してしまう祖先は原理的に選ばれない。
    /// Simulator の iPhone 17 Pro では窓座標 (21, 735, 360, 48) が返り、録画フレームで実測した
    /// 帯の可視範囲（y 735..783）と一致する。
    private static func bandView(from origin: UIView) -> UIView? {
        guard let window = origin.window else { return nil }
        var band: UIView?
        var candidate = origin.superview
        while let view = candidate, view !== window, view.bounds.width < window.bounds.width - 1 {
            band = view
            candidate = view.superview
        }
        return band
    }
}

// MARK: - SwiftUI からの入口

extension View {
    /// iPhone のフルプレイヤーを UIKit のカスタム提示で出す（仕様 4.1.1 章）。
    /// sheet の `.large` detent が上端に空ける 62 pt を塞ぐのが目的で、上角の丸みと下スワイプの
    /// 指追従はこの経路が自分で持つ。iPad の中央 sheet はこれを通さず `.sheet` のままにする。
    /// - Parameters:
    ///   - source: ミニプレイヤーの矩形を入れた箱。「ミニプレイヤーから展開」方式の出発・帰着に使い、
    ///     **中身を読むのは提示・終了の瞬間だけ**。箱が空のときは方式に関わらずせり上がりへ落とす。
    ///   - style: 出入りの見せ方。UIKit 側から `UserDefaults` は読まず、**必ずここから受け取る**。
    func playerPresentation(
        isPresented: Binding<Bool>,
        source: PlayerSourceBox,
        style: PlayerPresentationStyle,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        background(
            PlayerPresentationBridge(
                isPresented: isPresented,
                source: source,
                style: style,
                content: { AnyView(content()) }
            )
        )
    }
}

/// 提示の引き金だけを持つ、何も描かないビュー。SwiftUI から提示元の `UIViewController` を得る経路が
/// これしか無いので、表示物ではなく橋渡しとして置く。
private struct PlayerPresentationBridge: UIViewRepresentable {
    let isPresented: Binding<Bool>
    let source: PlayerSourceBox
    let style: PlayerPresentationStyle
    let content: () -> AnyView

    func makeCoordinator() -> PlayerPresentationCoordinator { PlayerPresentationCoordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        // 本文の背後に敷かれるので、当たり判定を持つとタブやミニプレイヤーの操作を吸ってしまう。
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(
            anchor: uiView,
            isPresented: isPresented,
            source: source,
            style: style,
            content: content()
        )
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
    private weak var source: PlayerSourceBox?
    private var style = PlayerPresentationStyle.slideUp
    private var hosting: UIHostingController<AnyView>?
    /// 標準 Zoom は custom delegate の完了通知を通らないため、終了処理の入口を分ける。
    private var usesSystemTransition = false
    private let transitioning = PlayerTransitioningDelegate()
    private var interaction: UIPercentDrivenInteractiveTransition?
    /// 終了 pan を始めた時点の本文の高さ。進行の分母に使う。
    private var dismissHeight: CGFloat = 1
    override init() {
        super.init()
        transitioning.onPresentEnded = { [weak self] completed in
            self?.presentEnded(completed: completed)
        }
        transitioning.onDismissEnded = { [weak self] completed in
            self?.dismissEnded(completed: completed)
        }
    }

    func update(
        anchor: UIView,
        isPresented: Binding<Bool>,
        source: PlayerSourceBox,
        style: PlayerPresentationStyle,
        content: AnyView
    ) {
        self.isPresented = isPresented
        self.anchor = anchor
        self.content = content
        self.source = source
        self.style = style
        // 帯そのものは渡さず、**箱を覗く手続き**を渡す。ミニプレイヤーは `.expanded` と `.inline` で
        // 高さが変わるので、提示・終了のたびに最新の帯が要る。ここで値を写し取ると、
        // 写すために幾何を SwiftUI の状態へ載せることになり、再レイアウトの輪へ戻ってしまう。
        transitioning.bandProvider =
            style == .expandFromMiniPlayer
            ? { [weak source] in
                // 弱参照は帯が畳まれた直後でもしばらく生き残る。`rect` は `RootView` が帯を消した
                // 瞬間に落とすので、**SwiftUI 側が畳んだ合図**として併せて見る。
                guard let source, source.rect != nil else { return nil }
                return source.bandView
            } : { nil }
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
        usesSystemTransition = style == .systemZoom && validZoomSource() != nil
        if usesSystemTransition {
            // 標準 Zoom を custom presentation と混ぜると UIKit の遷移 delegate が勝ってしまう。
            // source が実在するときだけ full screen の標準経路へ渡し、消えていれば従来のせり上がりへ落とす。
            controller.modalPresentationStyle = .fullScreen
            controller.preferredTransition = .zoom { [weak source] _ in
                guard let view = source?.view, Self.isValidZoomSource(view) else { return nil }
                return view
            }
        } else {
            controller.modalPresentationStyle = .custom
            controller.transitioningDelegate = transitioning
        }
        // 地は SwiftUI 側の帯が safe area を無視して敷くので、UIKit の地は透かす。
        // **静止している間は角を丸めない。**Apple Music のフルプレイヤーは四隅まで中身が詰まっており、
        // 画面の角丸はディスプレイの物理マスクだけが作っている（実機スクショの画素で確認）。
        // 自分で丸めると、公開 API で物理マスクの半径を正確に取る保証が無い以上どうしても食い違い、
        // **角の外側に下の画面が細い筋で覗く**。0 にしてしまえばその現象は原理的に起きない。
        // 丸めるのは引いている最中の上 2 角だけなので、下 2 角はマスクから外したままにする。
        // 半径は `layer.cornerRadius` で駆動する（公式に animatable で、遷移の進行に乗せられる）。
        // `cornerConfiguration` とは**併用しない**。
        controller.view.backgroundColor = .clear
        controller.view.layer.masksToBounds = true
        controller.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        controller.view.layer.cornerCurve = .continuous
        controller.view.layer.cornerRadius = 0
        // `safeAreaRegions` は既定の `.all` のまま。上端を塞ぐのは提示枠の仕事であって、
        // 本文の safe area を削る話ではない（仕様 4.1.1 章）。`additionalSafeAreaInsets` も触らない。

        if controller.transitioningDelegate != nil {
            let pan = PlayerDismissPan(target: self, action: #selector(handleDismissPan))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            controller.view.addGestureRecognizer(pan)
        }

        hosting = controller
        stage = .presenting
        presenter.present(controller, animated: true) { [weak self, weak controller] in
            guard let self, usesSystemTransition, controller?.presentingViewController != nil else { return }
            presentEnded(completed: true)
        }
        if usesSystemTransition, let presentationController = controller.presentationController {
            presentationController.delegate = self
        }
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
        hosting.dismiss(animated: true) { [weak self, weak hosting] in
            guard let self, usesSystemTransition, hosting?.presentingViewController == nil else { return }
            dismissEnded(completed: true)
        }
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
        // 引き始めの高さで割り続ける。「ミニプレイヤーから展開」では引くほど本文が縮むので、
        // **その場の高さで割ると縮みが進行を押し上げ、途中から勝手に閉じきってしまう。**
        if pan.state == .began { dismissHeight = max(view.bounds.height, 1) }
        let progress = min(max(pan.translation(in: view).y / dismissHeight, 0), 1)
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
                transitioning.prepareCancel(velocity: velocity, distance: progress * dismissHeight)
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

    /// 標準 Zoom は窓に属し、表示中で、面積を持つ source しか受け取れない。
    /// 条件を満たさないときは `.custom` のせり上がりへ落とし、空の snapshot を拡大させない。
    private func validZoomSource() -> UIView? {
        guard let view = source?.view, Self.isValidZoomSource(view) else { return nil }
        return view
    }

    private static func isValidZoomSource(_ view: UIView) -> Bool {
        guard view.window != nil, !view.isHidden, view.alpha > 0.01 else { return false }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return false }
        guard let screen = view.window?.windowScene?.screen else { return false }
        return view.convert(bounds, to: nil).intersects(screen.bounds)
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

extension PlayerPresentationCoordinator: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // 標準 Zoom の対話終了は UIKit が所有するため、完了だけ delegate から Binding へ戻す。
        guard usesSystemTransition, stage != .idle else { return }
        dismissEnded(completed: true)
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
    /// 枠の書き直しを止める合図。**「ミニプレイヤーから展開」は寸法そのものを動かす**ので、
    /// transform では見分けが付かない。途中のレイアウトで全面へ戻されるとアニメーションが飛ぶ。
    var isAnimatingFrame = false

    override var frameOfPresentedViewInContainerView: CGRect {
        containerView?.bounds ?? super.frameOfPresentedViewInContainerView
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        // 遷移中もここは呼ばれる。移動はアニメーターが transform で持っているので、
        // 通常のレイアウトのときだけ枠を書き直して上書きを避ける。
        guard !isAnimatingFrame, let presentedView, presentedView.transform.isIdentity else { return }
        presentedView.frame = frameOfPresentedViewInContainerView
    }
}

// MARK: - 遷移

private final class PlayerTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    /// 指追従のときだけ入る。`nil` のままなら出入りはアニメーターに任せきりになる。
    var interaction: UIPercentDrivenInteractiveTransition?
    /// 「ミニプレイヤーから展開」の出発・帰着になる帯を、**遷移を始める瞬間に**取り出す手続き。
    /// 方式の判定は SwiftUI 側で済ませてあり、ここへ来るのは帯の有無だけにしてある。
    /// 手続きにしてあるのは、帯が作り直されるたびに SwiftUI へ知らせずに済ませるため。
    var bandProvider: () -> UIView? = { nil }
    var onPresentEnded: ((Bool) -> Void)?
    var onDismissEnded: ((Bool) -> Void)?
    /// 進行中の終了アニメーター。取り消しの戻りへ指の速さを渡すためだけに覚える。
    private weak var dismissAnimator: PlayerTransitionAnimator?
    /// 進行中の提示枠。寸法を動かす方式のときだけ、遷移中の枠の書き直しを止めるのに使う。
    private weak var presentation: PlayerPresentationController?

    /// 取り消しの戻りに使うばねを、離した瞬間の速さから作って渡す。
    func prepareCancel(velocity: CGFloat, distance: CGFloat) {
        dismissAnimator?.prepareCancel(velocity: velocity, distance: distance)
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        let controller = PlayerPresentationController(presentedViewController: presented, presenting: presenting)
        presentation = controller
        return controller
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        PlayerTransitionAnimator(
            isPresenting: true,
            isInteractive: false,
            band: bandProvider(),
            presentationProvider: { [weak self] in self?.presentation },
            onEnded: onPresentEnded
        )
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        let animator = PlayerTransitionAnimator(
            isPresenting: false,
            isInteractive: interaction != nil,
            band: bandProvider(),
            presentationProvider: { [weak self] in self?.presentation },
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
    /// 次の継続で使うばねと、それを収める時間。1 回使ったら捨てて、以降は既定の曲線に戻す。
    /// **時間まで持つのが要点**である。`durationFactor` に 0 を渡せばばね自身の時間で進む、というのは
    /// 誤りで、Simulator で測ると続きの所要時間は `duration × durationFactor` そのものだった
    /// （factor 1 → 0.353 秒、5 → 1.752 秒、20 → 7.017 秒。`duration` は 0.35）。
    /// **0 を渡していた間は 0.066 秒で終わっており、ばねに差し替えた意味が無かった**（実機報告 build 9）。
    var continuation: (timing: UITimingCurveProvider, duration: TimeInterval)?

    override func continueAnimation(
        withTimingParameters parameters: UITimingCurveProvider?,
        durationFactor: CGFloat
    ) {
        guard let continuation, duration > 0 else {
            super.continueAnimation(withTimingParameters: parameters, durationFactor: durationFactor)
            return
        }
        self.continuation = nil
        // 欲しい時間を `duration` との比に直して渡す。UIKit はばねの形を保ったままこの時間へ伸縮する。
        super.continueAnimation(
            withTimingParameters: continuation.timing,
            durationFactor: CGFloat(continuation.duration / duration)
        )
    }
}

/// 「ミニプレイヤーから展開」の見た目一式。**寸法が動くのは角丸のクリップだけ**で、本文は
/// 全画面のままレイアウトしたスナップショットを一様に拡縮する。
/// 本文の frame を帯まで縮めていた頃は、縮んだ枠に対して SwiftUI が毎フレーム組み直すので
/// 中身が拡大されず、しかも全画面ぶんの safe area（上 59 pt）だけが残っていた（録画の実測）。
/// 実体の寸法と safe area を最後まで動かさないことが、この作り直しを断つ唯一の手になる。
private final class PlayerExpansionVisuals {
    /// 帯 ⇄ 全面で寸法が動く唯一のビュー。角丸もここが一手に持つ。
    /// `layer.mask` ではなく `clipsToBounds` にしてあるのは、マスク用のレイヤーを別途
    /// 同じ曲線で補間する手間を作らないため。
    private let clipView = UIView()
    /// 全画面でレイアウトした本文の写し。**bounds は全画面のまま固定**し、transform だけで縮める。
    private let fullSnapshot: UIView
    /// ガラスの帯の写し。撮れなかったときは本文の淡入だけになる。
    private let miniSnapshot: UIView?
    private let openRect: CGRect
    private let bandRect: CGRect
    private let bandRadius: CGFloat
    private let presented: UIView
    private let presentedAlpha: CGFloat
    private weak var bandView: UIView?
    private let bandAlpha: CGFloat
    private var isRestored = false

    /// 撮影と差し替えをここで済ませる。帰着先が空・画面外なら作らず、呼び手をせり上がりへ落とす。
    init?(presented: UIView, band: UIView, container: UIView, isPresenting: Bool) {
        let openRect = container.bounds
        let bandRect = band.convert(band.bounds, to: container)
        guard bandRect.width > 1, bandRect.height > 1, bandRect.intersects(openRect) else { return nil }

        // 撮る前に全画面で組み上げさせる。ここで寸法が確定していないと safe area が入らない本文を撮る。
        // transform を畳んでから bounds/center で置くのは、前の遷移が移動で終わっていることがあるため。
        presented.transform = .identity
        presented.bounds = CGRect(origin: .zero, size: openRect.size)
        presented.center = CGPoint(x: openRect.midX, y: openRect.midY)
        presented.layer.cornerRadius = 0
        presented.layoutIfNeeded()
        // 開くときの本文はまだ画面に出ていないので強制描画が要る。閉じるときは既に出ており、
        // 強制するとその 1 コミットが表へ漏れかねないので頼まない。
        guard let full = presented.snapshotView(afterScreenUpdates: isPresenting) else { return nil }

        self.openRect = openRect
        self.bandRect = bandRect
        self.presented = presented
        fullSnapshot = full
        presentedAlpha = presented.alpha
        // 実体は小さい親へ移さず、描画だけ写しへ引き継ぐ。移すと寸法と safe area の変化が本文へ伝わる。
        presented.alpha = 0

        bandView = band
        bandAlpha = band.alpha
        // 帯は既に画面に出ているので強制描画は要らない。
        miniSnapshot = band.snapshotView(afterScreenUpdates: false)
        band.alpha = 0
        bandRadius = Self.radius(of: band, rect: bandRect)

        clipView.clipsToBounds = true
        clipView.backgroundColor = .clear
        clipView.isUserInteractionEnabled = false
        clipView.layer.cornerCurve = .continuous
        // 帯は四隅とも丸い。上 2 角だけに絞ると、帯の姿のときに下 2 角が角張って見える。
        clipView.layer.maskedCorners = [
            .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
        ]
        full.bounds = CGRect(origin: .zero, size: openRect.size)
        clipView.addSubview(full)
        if let miniSnapshot {
            miniSnapshot.bounds = CGRect(origin: .zero, size: bandRect.size)
            // 帯を本文より上に重ねる。交差の途中で本文の地が帯を透かしてしまわないように。
            clipView.addSubview(miniSnapshot)
        }
        container.addSubview(clipView)
    }

    /// 開いた姿と帯の姿を書き分ける。**幾何も透明度も角丸もここ 1 か所**にまとめてあるので、
    /// 同じアニメーターへ載せるだけで、対話中の取り消しでも全部が一緒に戻る。
    func apply(open isOpen: Bool) {
        let rect = isOpen ? openRect : bandRect
        clipView.bounds = CGRect(origin: .zero, size: rect.size)
        clipView.center = CGPoint(x: rect.midX, y: rect.midY)
        clipView.layer.cornerRadius = isOpen ? 0 : bandRadius

        let center = CGPoint(x: rect.width / 2, y: rect.height / 2)
        // **非等方に潰さない。**帯の幅へ合わせた一様縮小なので本文の上下は帯からはみ出し、
        // 帯の高さの窓に隠れる。縦も潰すと中身の比率が壊れて、拡大ではなく変形に見える。
        let scale = isOpen ? 1 : bandRect.width / openRect.width
        fullSnapshot.center = center
        fullSnapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
        fullSnapshot.alpha = isOpen ? 1 : 0
        miniSnapshot?.center = center
        miniSnapshot?.alpha = isOpen ? 0 : 1
    }

    /// 展開経路だけの後始末。**何度呼んでも安全**にしてあるのは、完了・`animationEnded`・`tearDown` の
    /// どこから来ても取りこぼしを作らないため。取り消しても実体が戻らず黒い帯が残る、という
    /// 録画で見えた症状を「寸法を動かすのをやめたから自然に直る」で済ませない。
    /// 実体を先に全画面へ戻してから写しを外す。逆にすると、戻す前の 1 フレームが表に出る。
    func restore() {
        guard !isRestored else { return }
        isRestored = true
        UIView.performWithoutAnimation {
            presented.transform = .identity
            presented.bounds = CGRect(origin: .zero, size: openRect.size)
            presented.center = CGPoint(x: openRect.midX, y: openRect.midY)
            presented.layer.cornerRadius = 0
            presented.alpha = presentedAlpha
            presented.layoutIfNeeded()
        }
        clipView.removeFromSuperview()
        bandView?.alpha = bandAlpha
    }

    /// 帯の角の半径。**画面側の concentric 値（Simulator で 62 pt）は流用しない。**あれは
    /// `UIDropShadowView` が持つ画面の丸みで、帯の丸みとは別物である。
    /// 帯を描くビューは `cornerConfiguration` が `.unspecified`、`layer.cornerRadius` が NaN で、
    /// 解決値を返す公開 API が無い（実行時ダンプで確認）。取れたときだけそれを使い、
    /// 取れなければ高さの半分＝カプセルに落とす。録画フレームの帯の左端を円で当てると
    /// 高さ 48 pt に対し半径 24 pt が最良適合で、カプセルであることは実測で裏が取れている。
    private static func radius(of band: UIView, rect: CGRect) -> CGFloat {
        let capsule = min(rect.width, rect.height) / 2
        let resolved = band.effectiveRadius(corner: .topLeft)
        guard resolved.isFinite, resolved > 0 else { return capsule }
        return min(resolved, capsule)
    }
}

/// 出入りのアニメーター。動かすのは**姿の 1 つだけ**にする（仕様 4.1.1 章）。上 2 角の丸みだけは
/// 例外で、指追従の終了のときに姿と同じアニメーターへ相乗りさせる。
/// 動かす姿は出発の帯の有無で決まり、無ければ本文そのものの移動（transform）、
/// あればスナップショットを収めたクリップの拡縮（`PlayerExpansionVisuals`）になる。
/// **選ぶのは幾何だけ**で、曲線・取り消しのばね・完了時の置き直しは 2 方式で共通にする。
/// UIKit は遷移中に同じインスタンスを返すことを要求するので、
/// `animateTransition(using:)` も `interruptibleAnimator(using:)` の結果をそのまま使う。
private final class PlayerTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    /// 取り消しの戻りに使うばねの応答時間と減衰比。**Apple Music の実機録画からの実測値**である
    /// （`docs/org/movie.mov` の 4.26 秒と 6.49 秒の 2 回。板の縦位置を 1 フレームずつ相関で拾い、
    /// 残距離の減り方を臨界減衰の `(1 + ωt)e^(-ωt)` に当てると 5 点すべてで ω = 18.6〜20.3 rad/s）。
    /// 0.31 秒はその ω = 20.3 rad/s に対応する応答時間。
    /// **減衰比は 1.0 で、行き過ぎは 1 フレームも無い。**0.8 では行き過ぎるので下げてはいけない。
    /// 減衰比は開くときのばねにも使う（Apple は開閉で同じばねだった）。
    private static let cancelResponse = 0.31
    private static let springDampingRatio = 1.0
    /// 戻りに掛ける時間。**ばねの形と別に時間を決めなければならない**（`PlayerContinuationAnimator` の註）。
    /// Apple の実測は完全停止まで 0.404 / 0.438 秒で、引いた深さが 213 pt でも 314 pt でも変わらない。
    /// 上の ω・減衰比なら振幅 0.3 % 到達が ≒ 0.40 秒なので、ここを 0.40 にすればばねは素の速さで鳴り切る。
    /// これ以上伸ばすと、止まって見えてから掴み直せるまでの間（`Stage` が `.dismissing` の間）が空く。
    private static let cancelDuration = 0.40
    /// 引き継ぐ初速の上限（戻り距離の何倍／秒まで許すか）。行き過ぎの量は臨界減衰ならおよそ
    /// `初速 ÷ (固有角振動数 × e)` なので、20.3 rad/s に対して 6 なら戻り距離の約 1 割で頭を打つ。
    /// 浅く引いて速く離したときに、家の位置を大きく越えて跳ね上がるのを防ぐ。
    private static let cancelVelocityLimit: CGFloat = 6

    private let isPresenting: Bool
    private let isInteractive: Bool
    /// 出発（＝帰着）になるミニプレイヤーの帯。`nil` なら完成した寸法のまま画面の外へ出し入れする。
    /// **遷移を始める瞬間に一度だけ受け取り、その遷移の間は差し替えない。**
    private weak var sourceBand: UIView?
    private let onEnded: ((Bool) -> Void)?
    /// 提示枠を後から引く手。**作られる順に依存しないよう**、初期化時ではなくアニメーターを作る
    /// 時点で呼ぶ。寸法を動かす方式でしか使わない。
    private let presentationProvider: () -> PlayerPresentationController?
    private var animator: PlayerContinuationAnimator?
    /// 遷移中だけ枠の書き直しを止めてもらう相手。
    private weak var presentation: PlayerPresentationController?
    /// 「ミニプレイヤーから展開」のときだけ作られる。後始末の入口もこれが持つ。
    private var expansion: PlayerExpansionVisuals?

    init(
        isPresenting: Bool,
        isInteractive: Bool,
        band: UIView?,
        presentationProvider: @escaping () -> PlayerPresentationController?,
        onEnded: ((Bool) -> Void)?
    ) {
        self.isPresenting = isPresenting
        self.isInteractive = isInteractive
        sourceBand = band
        self.presentationProvider = presentationProvider
        self.onEnded = onEnded
    }

    /// 開くときは Apple の実測に合わせて 0.42 秒（`docs/org/movie.mov` の 1.614→2.035 秒）。
    /// 閉じ切るときは追従からの続きなので、これまでどおり少し短く取る。
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0.42 : 0.35
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
        let spring = UISpringTimingParameters(
            mass: 1,
            stiffness: omega * omega,
            damping: 2 * Self.springDampingRatio * omega,
            initialVelocity: CGVector(dx: 0, dy: min(max(normalized, -limit), limit))
        )
        // **ばねと一緒に時間も渡す。**渡さないと UIKit は残り時間で進めてしまい、
        // 浅く引いたときほど戻りが短いという、直したかった性質がそのまま残る。
        animator?.continuation = (spring, Self.cancelDuration)
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
        // 完了通知が来ないまま終わる経路（割り込み・強制終了）でも取りこぼさない。何度呼んでも安全。
        expansion?.restore()
        expansion = nil
        // 止めていた枠の書き直しを戻す。忘れると回転や幅の変化で提示枠が追従しなくなる。
        presentation?.isAnimatingFrame = false
        presentation = nil
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

        // 動かす姿を 1 つ選ぶ。開いた姿はどちらも容器いっぱい（＝提示枠と同じ）で、
        // 閉じた姿だけが方式で変わる。**置き直しをこの 1 つの関数に集めるので、
        // 完了・取り消しの扱いは 2 方式で一字も変わらない。**
        let settle: (Bool) -> Void
        if let presented, let expansion = makeExpansion(presented: presented, container: container) {
            self.expansion = expansion
            // 実体の寸法は動かさないが、遷移中に提示枠から書き直されると撮影済みの写しと食い違う。
            // 提示枠は遷移の始まりに作られているので、**アニメーターを作るこの時点で引けば取り違えない**。
            presentation = presentationProvider()
            presentation?.isAnimatingFrame = true
            settle = { staysOpen in expansion.apply(open: staysOpen) }
        } else {
            let offscreen = CGAffineTransform(translationX: 0, y: container.bounds.height)
            let move: (Bool) -> Void = { staysOpen in presented?.transform = staysOpen ? .identity : offscreen }
            // せり上がりでは引いている間だけ上 2 角を丸める。静止時は 0、引き切った時点で終端値に
            // なるように**姿と同じアニメーターへ相乗りさせる**ので、`update(_:)` だけで移動と丸みが
            // 一緒に進む。pan の `.changed` から半径を書かないのが要点で、書くと進行が二重になり
            // 取り消しでずれる。自動で出入りするときは丸めない（要件は「引いているときだけ」）。
            if isInteractive, let presented {
                let radius = Self.concentricRadius(of: presented)
                settle = { staysOpen in
                    move(staysOpen)
                    presented.layer.cornerRadius = staysOpen ? 0 : radius
                }
            } else {
                settle = move
            }
        }
        // 提示は閉じた姿から始めて開いた姿へ、終了はその逆へ動かす。
        settle(!isPresenting)

        // 追従中は線形にして指と 1 対 1 で動かす。自動で出入りするときだけ弾みと減速を付ける。
        let timing: UITimingCurveProvider
        if isInteractive {
            timing = UICubicTimingParameters(animationCurve: .linear)
        } else if isPresenting {
            // Apple は開くときも戻すときも同じばねで、行き過ぎが 1 フレームも無い（実測）。
            // 減衰比だけの初期化子はばねを `duration` に合わせて作るので、0.42 秒を渡せば
            // 上の取り消しと同じ ω ≒ 20 rad/s 相当になり、定数を二重に書かずに揃う。
            timing = UISpringTimingParameters(dampingRatio: CGFloat(Self.springDampingRatio))
        } else {
            timing = UICubicTimingParameters(animationCurve: .easeOut)
        }
        let animator = PlayerContinuationAnimator(
            duration: transitionDuration(using: context),
            timingParameters: timing
        )
        animator.addAnimations { [isPresenting] in
            settle(isPresenting)
        }
        animator.addCompletion { [isPresenting, weak self] _ in
            // 取り消しでは始まりの側、完了では終わりの側へ明示的に置き直す。
            // 提示ビューと地は取り消しでも階層から外さない（仕様 4.1.1 章）。
            let isCancelled = context.transitionWasCancelled
            let staysOpen = isPresenting != isCancelled
            settle(staysOpen)
            // 展開経路の実体・帯・写しは、取り消しでも成功でもこの 1 か所を通して戻す。
            self?.expansion?.restore()
            if !staysOpen, !isPresenting { presented?.removeFromSuperview() }
            context.completeTransition(!isCancelled)
        }
        return animator
    }

    /// 展開の道具を用意する。帯が居ない・画面に出ていない・空のときは `nil` を返して
    /// **せり上がりへ落とす**（居ない帯から広がって見えるより良い）。
    private func makeExpansion(presented: UIView, container: UIView) -> PlayerExpansionVisuals? {
        guard let band = sourceBand, band.window != nil, !band.isHidden, band.alpha > 0.01 else { return nil }
        return PlayerExpansionVisuals(
            presented: presented,
            band: band,
            container: container,
            isPresenting: isPresenting
        )
    }

    /// せり上がりで引き切ったときの上 2 角の半径。**数を直書きしない。**画面の角は端末ごとに違うので、
    /// 書くと機種依存の食い違いになる。`containerConcentric` を**値を読むためだけに**一度当て、
    /// 解決後の実数を `effectiveRadius(corner:)` で取り出して設定は元へ戻す。
    /// 以後の丸みは `layer.cornerRadius` だけが持つ（`cornerConfiguration` と併用しない）。
    /// これは concentric の解決値であって、物理マスクと一致することを保証するものではない。
    /// 静止時が 0 なので、一致していなくても角から地が覗くことはない。
    /// 寸法が決まる前は 0 に解決されるため、**呼ぶのは提示が済んだあと**に限る
    /// （Simulator の iPhone 17 Pro で 62.0 pt、レイアウト前は 0.0）。
    private static func concentricRadius(of view: UIView) -> CGFloat {
        let previous = view.cornerConfiguration
        view.cornerConfiguration = .uniformCorners(radius: .containerConcentric())
        let radius = view.effectiveRadius(corner: .topLeft)
        view.cornerConfiguration = previous
        return radius
    }
}
