import SwiftUI

/// ミニプレイヤー。`tabViewBottomAccessory` に置き、`.expanded` / `.inline` で密度を変える（`docs/ui-spec.md` 3 章）。
/// ガラスの帯の上に塗りを重ねず、Apple Music と同じく裸のグリフだけを並べる。
struct MiniPlayerView: View {
    /// 自分の矩形（窓座標）が変わったときに知らせる。フルプレイヤーを「ここから展開する」方式が
    /// 出発・帰着に使う（仕様 4.1.1 章）。既定を空にしてあるのは、矩形を要らない呼び出し側のため。
    var onFrameChange: (CGRect) -> Void = { _ in }
    /// iPad の detail 上では tab accessory の配置値を使わず、参照どおり 2 段表示へ固定する。
    var forceExpanded = false
    let openPlayer: () -> Void

    @Environment(PlaybackEngine.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { !forceExpanded && placement == .inline }

    var body: some View {
        if let track = player.currentItem {
            if forceExpanded {
                padExpandedPlayer(track)
            } else {
                standardPlayer(track)
            }
        }
    }

    private func standardPlayer(_ track: MediaItem) -> some View {
        HStack(spacing: 0) {
            trackButton(track)
            playPauseButton
            if !isInline { nextButton }
        }
        .padding(.leading, isInline ? 8 : 16)
        .padding(.trailing, isInline ? 8 : 14)
        .padding(.vertical, isInline ? 0 : 8)
        .simultaneousGesture(openGesture)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            onFrameChange($0)
        }
    }

    private func padExpandedPlayer(_ track: MediaItem) -> some View {
        HStack(spacing: 8) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle").frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            Button {
                player.playPrevious()
            } label: {
                Image(systemName: "backward.fill").frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)
            playPauseButton
            nextButton
            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode.systemImage).frame(width: 36, height: 44)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)
            trackButton(track).frame(maxWidth: 260)
            Spacer(minLength: 12)

            Button {
            } label: {
                Image(systemName: "ellipsis").frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            Button(action: openPlayer) {
                Image(systemName: "quote.bubble").frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            Button(action: openPlayer) {
                Image(systemName: "list.bullet").frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 16)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            onFrameChange($0)
        }
    }

    private func trackButton(_ track: MediaItem) -> some View {
        Button(action: openPlayer) {
            HStack(spacing: 8) {
                artwork(for: track)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayName).font(.subheadline.weight(.medium))
                    if !isInline {
                        Text(track.displayArtist ?? String(localized: "不明なアーティスト"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.displayName)、プレイヤーを開く")
    }

    private var nextButton: some View {
        Button {
            player.playNext()
        } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!player.hasNext)
        .accessibilityLabel("次の曲")
    }

    private var openGesture: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { value in
            if value.translation.height < -30,
                abs(value.translation.height) > abs(value.translation.width) * 1.5
            {
                openPlayer()
            }
        }
    }

    private func artwork(for track: MediaItem) -> some View {
        // `.expanded` は Apple 実機の実測 30 pt（仕様 3 章）。`.inline` は参照画像が無いので据え置く。
        ArtworkView(item: track, size: isInline ? 28 : 30, cornerRadius: 6)
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
            // 塗り円は付けない（仕様 3 章）。記号の高さが約 18 pt になる字送りを選ぶ。
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: isInline ? 16 : 18, weight: .medium))
                .foregroundStyle(Color.primary)
                // 見た目は裸のグリフでも、当たり判定は 44pt を確保する。
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("miniplayer.play-pause")
        .accessibilityLabel(player.isPlaying ? String(localized: "一時停止") : String(localized: "再生"))
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
