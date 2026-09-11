import SwiftUI

/// Jellyfin のアートワークを表示する。読み込み中はプレースホルダーを出し、完了時にクロスフェードする。
struct ArtworkView: View {
    let item: MediaItem?
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    @Environment(AuthStore.self) private var auth
    @State private var image: UIImage?
    @State private var didFail = false

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
        .task(id: item?.id) { await load() }
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
        guard let item, let client = auth.client,
            let url = client.artworkURL(for: item, maxSize: Int(size))
        else { return }

        let loaded = await ArtworkLoader.shared.image(for: url)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            image = loaded
            didFail = loaded == nil
        }
    }
}
