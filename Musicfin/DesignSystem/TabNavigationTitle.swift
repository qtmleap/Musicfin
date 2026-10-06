import SwiftUI
import UIKit

private struct TabNavigationTitle: ViewModifier {
    let title: Text

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                // 小さいタイトルへ切り替えずに退場させるため、compact 側だけ空にする。
                ToolbarItem(placement: .title) {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .libraryNavigationMargins(UIDevice.current.userInterfaceIdiom == .pad ? 34.5 : 20)
    }
}

extension View {
    @ViewBuilder
    func tabNavigationTitle(_ title: Text, isEnabled: Bool = true) -> some View {
        if isEnabled {
            modifier(TabNavigationTitle(title: title))
        } else {
            self
        }
    }
}
