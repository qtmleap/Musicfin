import SwiftUI
import UIKit

/// `NavigationSplitView` の裏にある `UISplitViewController` を直に設定する。
///
/// `.navigationSplitViewColumnWidth` は iOS 26 の `.balanced` では無視され、板幅は 320 pt に
/// 固定される。仕様 6 章の 269.5 / 279.5 / 314.0 pt を出すため、UIKit 側の性質を書き換える。
///
/// 実測では、コールド起動時に最後の適用が終わった後で SwiftUI が 3 つの幅プロパティを
/// すべて automatic に戻す。UIView の `didMoveToWindow` / `layoutSubviews` は戻される前にしか
/// 呼ばれないため、「戻された後」の契機がなかった。view controller にすると
/// `viewDidAppear` と親への取り付け通知が使え、その後にもう一度当て直せる。
///
/// 所有関係: split controller は SwiftUI が所有し、ここは書き換えるだけで保持しない。
/// 対象は適用のたびに親 controller の連鎖から引き直す（キャッシュしない）。
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
            guard parent != nil else { return }
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
