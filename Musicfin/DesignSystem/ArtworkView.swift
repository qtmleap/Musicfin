import SwiftUI

/// Jellyfin のアートワークを表示する。読み込み中はプレースホルダーを出し、完了時にクロスフェードする。
struct ArtworkView: View {
    let item: MediaItem?
    var size: CGFloat
    var cornerRadius: CGFloat = 8
    /// 見た目の伸縮で画像を取り直さないよう、取得時の解像度を表示寸法から独立させる。
    var requestSize: CGFloat?

    @Environment(AuthStore.self) private var auth
    @State private var image: UIImage?
    @State private var imageSource: String?
    @State private var didFail = false
    @State private var retryGeneration = 0
    @Environment(\.scenePhase) private var scenePhase

    private var request: ArtworkRequest? {
        ArtworkRequest(item: item, client: auth.client, size: requestSize ?? size)
    }

    private struct LoadKey: Equatable {
        let request: ArtworkRequest?
        let retry: Int
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            // 白いアートワークが背景に溶けないよう、ごく薄い境界線を重ねる。
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: LoadKey(request: request, retry: retryGeneration)) { await load() }
        .onChange(of: scenePhase) { _, phase in
            // 通信失敗後にアプリへ戻ったときは、同じ曲のままでも取得をやり直せる。
            if phase == .active, didFail { retryGeneration += 1 }
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: iconName)
                .font(.system(size: size * 0.32, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }

    private var iconName: String {
        switch item?.type {
        case .musicArtist: "music.microphone"
        case .playlist: "music.note.list"
        default: "music.note"
        }
    }

    private func load() async {
        let request = request
        if imageSource != request?.sourceKey {
            image = nil
            imageSource = request?.sourceKey
        }
        didFail = false
        guard let request else { return }
        let result = await ArtworkLoader.shared.image(for: request)
        guard !Task.isCancelled, self.request == request else { return }
        switch result {
        case .success(let loaded):
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        case .failure(let failure):
            didFail = failure.isRetryable
        }
    }
}
