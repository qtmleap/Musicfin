import SwiftUI

/// Jellyfin のアートワークを表示する。読み込み中はプレースホルダーを出し、完了時にクロスフェードする。
struct ArtworkView: View {
    let item: MediaItem?
    var size: CGFloat
    var cornerRadius: CGFloat = 8
    /// 画像が無いときの記号の大きさ（一辺に対する指定サイズの比）。既定は一覧や行の小さな枠向けで、
    /// プレイヤーの大きな枠だけ参照に合わせて別の比を渡す（仕様 6.2.1 章）。
    var iconScale: CGFloat = 0.32
    /// 画像が無いときの枠の地。既定の `.quaternary` は**白を重ねて地から浮かせる**面で、一覧や行では
    /// これが正しい。参照のプレイヤーの空状態だけは逆に**地を暗くする**面なので、そこだけ差し替える
    /// （仕様 6.2.1 章）。`iconScale` と同じく、共有の見た目を既定のまま残すための入口。
    var placeholderFill: AnyShapeStyle = AnyShapeStyle(.quaternary)

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
            Rectangle().fill(placeholderFill)
            Image(systemName: iconName)
                .font(.system(size: size * iconScale, weight: .light))
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
