import SwiftUI
import UIKit

/// sidebar の選択は capsule が示すため、UIKit のセルが重ねる矩形の halo だけを外す。
/// SwiftUI の focusEffectDisabled は行の中へ届いても、行を包むセルの効果には届かない。
struct PadSidebarFocusStyle: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }

    func updateUIView(_ view: ProbeView, context: Context) { view.applyStyle() }

    final class ProbeView: UIView {
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyStyle()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyStyle()
        }

        func applyStyle() {
            var ancestor = superview
            while let view = ancestor {
                if let cell = view as? UICollectionViewCell {
                    // フォーカスに選択が追従する List の振る舞いは残し、追加の輪郭だけを消す。
                    if cell.focusEffect != nil { cell.focusEffect = nil }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
