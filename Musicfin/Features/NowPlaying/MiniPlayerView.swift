import SwiftUI

/// ミニプレイヤー。`tabViewBottomAccessory` に置き、`.expanded` / `.inline` で密度を変える（`docs/ui-spec.md` 3 章）。
/// 再生ボタンだけをピンクの丸で塗り、ガラスの帯の中で唯一の「押す場所」として目立たせる。
struct MiniPlayerView: View {
    let openPlayer: () -> Void

    @Environment(PlaybackEngine.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        if let track = player.currentItem {
            HStack(spacing: 4) {
                Button(action: openPlayer) {
                    HStack(spacing: 10) {
                        artwork(for: track)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayName)
                                .font(.subheadline.weight(.semibold))
                            if !isInline {
                                Text(track.displayArtist ?? "不明なアーティスト")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(track.displayName)、プレイヤーを開く")

                playPauseButton

                if !isInline {
                    Button {
                        player.playNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasNext)
                    .accessibilityLabel("次の曲")
                }
            }
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 0 : 4)
            // 上スワイプだけでフルプレイヤーを開く。横方向は誤爆しやすいので何も割り当てない。
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    if value.translation.height < -30,
                        abs(value.translation.height) > abs(value.translation.width) * 1.5
                    {
                        openPlayer()
                    }
                }
            )
        }
    }

    private func artwork(for track: MediaItem) -> some View {
        ArtworkView(item: track, size: isInline ? 28 : 40, cornerRadius: isInline ? 6 : 8)
            .shadow(color: .pink.opacity(0.25), radius: 4, y: 2)
            .overlay {
                // バッファ中は画像の上に進行表示を重ね、行の高さを変えずに状態を伝える。
                if player.isBuffering {
                    ProgressView()
                        .controlSize(.small)
                        .padding(4)
                        .background(.regularMaterial, in: .circle)
                }
            }
    }

    private var playPauseButton: some View {
        Button {
            player.toggle()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: isInline ? 13 : 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: isInline ? 28 : 34, height: isInline ? 28 : 34)
                .background(.pink.gradient, in: .circle)
                // 見た目は小さな丸でも、当たり判定は 44pt を確保する。
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
    }
}

#Preview {
    Color.clear
        .tabViewBottomAccessory {
            MiniPlayerView {}
        }
        .environment(AuthStore())
        .environment(PlaybackEngine())
}
