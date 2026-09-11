import SwiftUI

/// Fable 版の「次に再生」領域。`upcoming` の順に並べ、行タップで該当位置へ飛ぶ（`docs/ui-spec.md` 5 章）。
/// 削除・並べ替えは未対応なので出さない。シャッフル・リピートは上部のガラスのトグルにまとめる。
struct FableQueueView: View {
    @Environment(PlaybackEngine.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            header
            if player.upcoming.isEmpty {
                ContentUnavailableView(
                    "次に再生する曲はありません",
                    systemImage: "list.bullet",
                    description: Text("アルバムや曲の「次に再生」「最後に追加」でここに並びます。")
                )
            } else {
                queueList
            }
        }
    }

    private var header: some View {
        HStack {
            Text("次に再生")
                .font(.headline)
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    toggle("シャッフル", systemImage: "shuffle", isOn: player.isShuffled) {
                        player.toggleShuffle()
                    }
                    toggle("リピート", systemImage: player.repeatMode.systemImage, isOn: player.repeatMode != .off) {
                        player.cycleRepeatMode()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// オンのときはピンクの prominent、オフのときは透明なガラスにして状態を形で示す。
    @ViewBuilder
    private func toggle(_ label: String, systemImage: String, isOn: Bool, action: @escaping () -> Void)
        -> some View
    {
        let icon = Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(width: 36, height: 32)
        if isOn {
            Button(action: action) { icon }
                .buttonStyle(.glassProminent)
                .foregroundStyle(.white)
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: action) { icon }
                .buttonStyle(.glass)
                .accessibilityLabel(label)
        }
    }

    private var queueList: some View {
        List {
            ForEach(Array(player.upcoming.enumerated()), id: \.element.id) { offset, track in
                Button {
                    // upcoming は currentIndex+1 から始まるスライスなので、その分を足して実位置にする。
                    player.play(at: player.currentIndex + 1 + offset)
                } label: {
                    FableTrackRow(track: track, showsArtwork: true)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    FableQueueView()
        .environment(AuthStore())
        .environment(PlaybackEngine())
}
