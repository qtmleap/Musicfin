import SwiftUI

nonisolated extension ArtworkRequest {
    /// 認証情報は送信ヘッダーだけへ置き、URL・ファイル名・ログには含めない。
    init?(item: MediaItem?, client: JellyfinClient?, size: CGFloat) {
        guard let item, let client, let url = client.artworkURL(for: item, maxSize: Int(size)) else { return nil }
        self.init(url: url, authorization: client.authorizationHeader)
    }
}

/// セルの生成に依存せず、受信済みの一覧だけを少数ずつ温める。
private struct ArtworkPrefetchModifier: ViewModifier {
    let items: [MediaItem]
    let size: CGFloat
    @Environment(AuthStore.self) private var auth

    func body(content: Content) -> some View {
        let requests = items.compactMap { ArtworkRequest(item: $0, client: auth.client, size: size) }
        content.task(id: requests) {
            await ArtworkDataStore.shared.prefetch(requests)
        }
    }
}

extension View {
    func prefetchArtwork(_ items: [MediaItem], size: CGFloat) -> some View {
        modifier(ArtworkPrefetchModifier(items: items, size: size))
    }
}
