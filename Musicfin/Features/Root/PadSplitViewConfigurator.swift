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
/// しかも body を評価し直すたびに三つの列幅を `automaticDimension` へ書き戻すので、sheet を
/// 出し入れするだけでも列が既定の 320 pt へ戻る。板は 0 幅で自分の frame が動かないため
/// `layoutSubviews` はそのとき呼ばれず、当て直しが 3 フレーム遅れて提示のアニメーションに
/// 巻き込まれ、板幅が 250 → 269.5 pt と 0.4 秒かけて伸びるのが見えてしまう（実測）。
/// そこで表示の更新ごとに自分で確かめ、アニメーション無しで当て直す。
struct PadSplitViewConfigurator: UIViewRepresentable {
    let primaryColumnWidth: CGFloat
    /// split view が別の画面で完全に覆われているか。覆われている間は SwiftUI が列幅を書き戻しても
    /// 目に見えないので、毎フレームの確かめを止める。
    var isCovered = false

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(primaryColumnWidth: primaryColumnWidth, isCovered: isCovered)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.primaryColumnWidth = primaryColumnWidth
        view.isCovered = isCovered
        view.applyConfiguration()
    }

    /// 自分自身は何も描かない。親をたどるためだけに階層へ挿す板。
    final class ProbeView: UIView {
        var primaryColumnWidth: CGFloat
        /// 覆われている間は時計を止める。復帰時は `updateUIView` からの当て直しで追いつく。
        var isCovered: Bool {
            didSet {
                guard isCovered != oldValue else { return }
                updateEnforcement()
            }
        }

        init(primaryColumnWidth: CGFloat, isCovered: Bool) {
            self.primaryColumnWidth = primaryColumnWidth
            self.isCovered = isCovered
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// 表示の更新に合わせて当て直すための時計。window から外れるか、フルプレイヤーなどで
        /// 覆われている間は止める（見えない列を毎フレーム確かめても意味がない）。
        private var enforcement: CADisplayLink?
        /// 当て直しが引き起こすレイアウトから自分へ戻ってくるのを止める札。
        private var isApplying = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyConfiguration()
            updateEnforcement()
        }

        private func updateEnforcement() {
            guard window != nil, !isCovered else {
                enforcement?.invalidate()
                enforcement = nil
                return
            }
            guard enforcement == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(enforce))
            // sheet の提示中も止まらないよう common モードへ入れる。
            link.add(to: .main, forMode: .common)
            enforcement = link
        }

        @objc private func enforce() {
            applyConfiguration(immediately: true)
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

        /// - Parameter immediately: 書き換えたぶんのレイアウトをその場で済ませるか。表示の更新
        ///   から呼ぶときだけ true にする。`layoutSubviews` の中から祖先のレイアウトを促すと
        ///   往復する恐れがあるので、そちらからは次の pass に任せる。
        func applyConfiguration(immediately: Bool = false) {
            guard let split = splitViewController, !isApplying else { return }
            let widthDiffers =
                split.minimumPrimaryColumnWidth != primaryColumnWidth
                || split.maximumPrimaryColumnWidth != primaryColumnWidth
                || split.preferredPrimaryColumnWidth != primaryColumnWidth
            // 板は参照では閉じられない。端の払いでの開閉と、detail 側に残る表示モードの
            // ボタンをどちらも塞げるかを確かめる。
            let behaviorDiffers =
                split.presentsWithGesture
                || split.displayModeButtonVisibility != .never
                || split.preferredSplitBehavior != .tile
                || split.preferredDisplayMode != .oneBesideSecondary
            guard widthDiffers || behaviorDiffers else { return }

            isApplying = true
            defer { isApplying = false }
            // 書き戻しは提示のアニメーションの中で起きる。素で当て直すとその補間に乗って
            // 板幅が伸縮して見えるので、当て直しだけはアニメーションから外す。
            UIView.performWithoutAnimation {
                if widthDiffers {
                    split.minimumPrimaryColumnWidth = primaryColumnWidth
                    split.maximumPrimaryColumnWidth = primaryColumnWidth
                    split.preferredPrimaryColumnWidth = primaryColumnWidth
                }
                if split.presentsWithGesture { split.presentsWithGesture = false }
                if split.displayModeButtonVisibility != .never {
                    split.displayModeButtonVisibility = .never
                }
                if split.preferredSplitBehavior != .tile { split.preferredSplitBehavior = .tile }
                if split.preferredDisplayMode != .oneBesideSecondary {
                    split.preferredDisplayMode = .oneBesideSecondary
                }
                if immediately { split.view.layoutIfNeeded() }
            }
            guard widthDiffers else { return }
            // 既定へ戻された時点のレイアウトは提示のアニメーションの中で済んでいるので、
            // 正しい値を入れ直しても layer には 320 pt へ向かう補間が残っている。幅に関わる
            // ぶんだけ落とす（中身の動きは列の layer には載らないので巻き込まない）。
            for view in [split.view, split.viewController(for: .primary)?.view] {
                guard let layer = view?.layer else { continue }
                for key in layer.animationKeys() ?? []
                where key.hasPrefix("bounds") || key.hasPrefix("position") {
                    layer.removeAnimation(forKey: key)
                }
            }
        }
    }
}
