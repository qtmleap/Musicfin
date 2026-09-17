import SwiftUI
import UIKit

/// `NavigationSplitView` の裏にある `UISplitViewController` を掴んで、SwiftUI 側では
/// 効かない設定（列幅・スワイプでの開閉・表示モードボタン）を直接書き換えるための実験用の道具。
///
/// `.navigationSplitViewColumnWidth` は iOS 26 の `.balanced` では無視され、板幅は 320 pt に
/// 固定される（269.5 pt を渡しても 400 pt を渡しても実測が変わらないことを確認済み）。
/// 仕様 6 章が要求する 269.5 / 279.5 / 314.0 pt を標準 API で出せるかを確かめるため、
/// 応答者連鎖をたどって親の split controller を探し、UIKit 側の性質で上書きする。
///
/// SwiftUI は自分が所有する controller をいつでも組み直すので、一度きりの適用では戻される。
/// `layoutSubviews` のたびに当て直し、現在値と違うときだけ書くことで往復を避けている。
struct PadSplitViewConfigurator: UIViewRepresentable {
    let primaryColumnWidth: CGFloat

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(primaryColumnWidth: primaryColumnWidth)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.primaryColumnWidth = primaryColumnWidth
        view.applyConfiguration()
    }

    /// 自分自身は何も描かない。親をたどるためだけに階層へ挿す板。
    final class ProbeView: UIView {
        var primaryColumnWidth: CGFloat

        init(primaryColumnWidth: CGFloat) {
            self.primaryColumnWidth = primaryColumnWidth
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyConfiguration()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyConfiguration()
        }

        /// 応答者連鎖を上へたどって最初に見つかった split controller を設定対象にする。
        private var splitViewController: UISplitViewController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let split = current as? UISplitViewController { return split }
                responder = current.next
            }
            return nil
        }

        func applyConfiguration() {
            guard let split = splitViewController else { return }
            if split.minimumPrimaryColumnWidth != primaryColumnWidth {
                split.minimumPrimaryColumnWidth = primaryColumnWidth
            }
            if split.maximumPrimaryColumnWidth != primaryColumnWidth {
                split.maximumPrimaryColumnWidth = primaryColumnWidth
            }
            if split.preferredPrimaryColumnWidth != primaryColumnWidth {
                split.preferredPrimaryColumnWidth = primaryColumnWidth
            }
            // 板は参照では閉じられない。端の払いでの開閉と、detail 側に残る表示モードの
            // ボタンをどちらも塞げるかを確かめる。
            if split.presentsWithGesture { split.presentsWithGesture = false }
            if split.displayModeButtonVisibility != .never {
                split.displayModeButtonVisibility = .never
            }
            if split.preferredSplitBehavior != .tile { split.preferredSplitBehavior = .tile }
            if split.preferredDisplayMode != .oneBesideSecondary {
                split.preferredDisplayMode = .oneBesideSecondary
            }
        }
    }
}
