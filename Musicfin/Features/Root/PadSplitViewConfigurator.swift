import SwiftUI
import UIKit

/// `NavigationSplitView` の裏にある `UISplitViewController` を直に設定する。
///
/// `.navigationSplitViewColumnWidth` は iOS 26 の `.balanced` では無視され、板幅は 320 pt に
/// 固定される。仕様 6 章の 269.5 / 279.5 / 314.0 pt を出すため、UIKit 側の性質を書き換える。
///
/// 実測では、コールド起動時に最後の適用が終わった後で SwiftUI が 3 つの幅プロパティを
/// すべて automatic に戻す。UIView の `didMoveToWindow` / `layoutSubviews` は戻される前にしか
/// 呼ばれないため、表示の契機に加えて幅の変更通知から当て直す。次の更新へ遅らせると
/// 狭い列の枠が先に描画され、固定幅の一覧でも右端が一瞬切れるため、その場で設定を戻す。
///
/// 所有関係: split controller は SwiftUI が所有し、対象は親の連鎖から引き直す。
/// 監視対象の比較だけに弱参照を使い、親の交換・取り外しで通知の所有を終える。
struct PadSplitViewConfigurator: UIViewControllerRepresentable {
    let primaryColumnWidth: CGFloat

    func makeUIViewController(context: Context) -> ConfiguratorController {
        ConfiguratorController(primaryColumnWidth: primaryColumnWidth)
    }

    func updateUIViewController(_ controller: ConfiguratorController, context: Context) {
        controller.primaryColumnWidth = primaryColumnWidth
        controller.scheduleReapply()
    }

    static func dismantleUIViewController(_ controller: ConfiguratorController, coordinator: ()) {
        controller.detach()
    }

    /// 自分自身は何も描かず、触れず、読み上げもされない。契機を受けるためだけに階層へ挿す。
    final class ConfiguratorController: UIViewController {
        var primaryColumnWidth: CGFloat

        /// 取り外し後に予約分が走っても、破棄済みの階層へは書かない。
        private var isDetached = false
        /// 予約は 1 件に束ねる。実行側からは再予約しないので、非同期の連鎖にはならない。
        private var isReapplyScheduled = false
        /// 設定の書き込みがレイアウトを起こして自分へ戻ってくる往復を断つ。
        private var isApplying = false
        /// SwiftUI が最後のレイアウト後に幅を戻すため、書き換え自体を再適用の契機にする。
        private weak var observedSplit: UISplitViewController?
        private var widthObservations: [NSKeyValueObservation] = []

        init(primaryColumnWidth: CGFloat) {
            self.primaryColumnWidth = primaryColumnWidth
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            view.accessibilityElementsHidden = true
            self.view = view
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard parent != nil else {
                stopObservingWidths()
                return
            }
            apply()
            scheduleReapply()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // 表示が確定した後に SwiftUI が幅を automatic へ戻すので、その後を狙って当て直す。
            apply()
            scheduleReapply()
        }

        func detach() {
            isDetached = true
            stopObservingWidths()
        }

        func scheduleReapply() {
            guard !isReapplyScheduled else { return }
            isReapplyScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isReapplyScheduled = false
                apply()
            }
        }

        private func stopObservingWidths() {
            for observation in widthObservations { observation.invalidate() }
            widthObservations.removeAll()
            observedSplit = nil
        }

        private func observeWidths(of split: UISplitViewController) {
            guard observedSplit !== split else { return }
            stopObservingWidths()
            observedSplit = split
            widthObservations = [
                split.observe(\.minimumPrimaryColumnWidth) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.widthChanged() }
                },
                split.observe(\.maximumPrimaryColumnWidth) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.widthChanged() }
                },
                split.observe(\.preferredPrimaryColumnWidth) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.widthChanged() }
                },
            ]
        }

        private func widthChanged() {
            guard !isDetached, !isApplying else { return }
            guard targetSplit === observedSplit else {
                scheduleReapply()
                return
            }
            // 次の更新へ持ち越すと列の狭い枠が先に描画されるため、配置を強制せず設定だけ戻す。
            UIView.performWithoutAnimation { apply() }
        }

        /// 親 controller の連鎖を上へたどって最初に見つかった split controller。
        private var targetSplit: UISplitViewController? {
            if let split = splitViewController { return split }
            var current = parent
            while let controller = current {
                if let split = controller as? UISplitViewController { return split }
                current = controller.parent
            }
            return nil
        }

        private func apply() {
            guard !isDetached, !isApplying, isViewLoaded, view.window != nil,
                let split = targetSplit
            else { return }
            isApplying = true
            defer { isApplying = false }
            observeWidths(of: split)

            var changed = false
            if split.minimumPrimaryColumnWidth != primaryColumnWidth {
                split.minimumPrimaryColumnWidth = primaryColumnWidth
                changed = true
            }
            if split.maximumPrimaryColumnWidth != primaryColumnWidth {
                split.maximumPrimaryColumnWidth = primaryColumnWidth
                changed = true
            }
            if split.preferredPrimaryColumnWidth != primaryColumnWidth {
                split.preferredPrimaryColumnWidth = primaryColumnWidth
                changed = true
            }
            // 端の払いでの開閉と、detail 側に残る表示モードのボタンを塞ぐ。
            if split.presentsWithGesture {
                split.presentsWithGesture = false
                changed = true
            }
            if split.displayModeButtonVisibility != .never {
                split.displayModeButtonVisibility = .never
                changed = true
            }
            if split.preferredSplitBehavior != .tile {
                split.preferredSplitBehavior = .tile
                changed = true
            }
            if split.preferredDisplayMode != .oneBesideSecondary {
                split.preferredDisplayMode = .oneBesideSecondary
                changed = true
            }
            // 再レイアウトは予約するだけで、ここでは同期的に走らせない。
            if changed { split.view.setNeedsLayout() }
        }
    }
}
