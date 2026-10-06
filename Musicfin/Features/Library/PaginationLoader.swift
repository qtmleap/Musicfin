import SwiftUI

/// List が画面外の行を先に生成しても、見えていない末尾から全件取得を始めない。
struct PaginationLoader: View {
    let revision: Int
    let isLoading: () -> Bool
    let load: () async -> Void
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 60)
            .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
            .task(id: isVisible ? revision : nil) {
                guard isVisible else { return }
                // 別のタブの取得が取り消される途中でも、新しい末尾の通知を失わない。
                while isLoading() {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                guard !Task.isCancelled else { return }
                await load()
            }
    }
}
