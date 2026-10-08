import SwiftUI

/// 行の一度きりの表示通知に依存せず、末尾が見える間は次ページへ進める。
struct LibraryFeedLoader: View {
    let feed: LibraryFeed
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let page = library.page(for: feed)
        if let message = page.errorMessage {
            LoadErrorView(message: message) { await library.loadFeed(feed) }
        } else if !page.isComplete, page.needsManualContinuation {
            Button("さらに読み込む") { Task { await library.loadFeed(feed) } }
        } else if !page.isComplete {
            PaginationLoader(
                revision: page.revision, isLoading: { page.isLoading }, load: { await library.loadFeed(feed) })
        }
    }
}
