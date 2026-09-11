import SwiftUI

/// システムのガラス面を活かし、コンテンツに追加の背景を重ねない。
struct AstraMiniPlayerView: View {
    let openPlayer: () -> Void
    @Environment(PlaybackEngine.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        if let track = player.currentItem {
            HStack(spacing: 4) {
                Button(action: openPlayer) {
                    HStack(spacing: 10) {
                        ArtworkView(item: track, size: isInline ? 28 : 40, cornerRadius: 4)
                            .overlay {
                                if player.isBuffering {
                                    ProgressView().controlSize(.small)
                                        .padding(4)
                                        .background(.regularMaterial, in: .circle)
                                }
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayName).font(.subheadline.weight(.medium))
                            if !isInline {
                                Text(track.displayArtist ?? "不明なアーティスト")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(track.displayName)、\(track.displayArtist ?? "不明なアーティスト")、プレイヤーを開く")
                .accessibilityValue(player.isBuffering ? "読み込み中" : "")

                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")

                if !isInline {
                    Button {
                        player.playNext()
                    } label: {
                        Image(systemName: "forward.fill").font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(!player.hasNext)
                    .accessibilityLabel("次の曲")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 0 : 4)
            // タブバーの横操作と競合させず、明確な上方向の移動だけを開く操作にする。
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
}

#Preview {
    AstraMiniPlayerView {}
        .environment(AuthStore())
        .environment(PlaybackEngine())
}
