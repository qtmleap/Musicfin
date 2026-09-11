import AVKit
import MediaPlayer
import SwiftUI
import UIKit

struct NowPlayingView: View {
    private enum ContentMode { case artwork, lyrics, queue }
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var minimumTitleHeight = 76.0
    @ScaledMetric(relativeTo: .caption) private var minimumSeekHeight = 64.0
    @State private var mode: ContentMode = .artwork
    @State private var isScrubbing = false
    @State private var scrubTime = 0.0
    @State private var favoriteTrack: MediaItem?
    @State private var isUpdatingFavorite = false

    var body: some View {
        GeometryReader { geometry in
            let layout = PlayerLayout(
                height: geometry.size.height,
                titleMinimum: minimumTitleHeight,
                seekMinimum: minimumSeekHeight
            )
            ScrollView {
                VStack(spacing: 0) {
                    closeButton.frame(height: layout.top)
                    mediaContent(width: geometry.size.width - 48, height: layout.media)
                        .frame(height: layout.media)
                        .clipped()
                    titleRow.frame(height: layout.title)
                    seekControls.frame(height: layout.seek)
                    transport.frame(height: layout.transport)
                    SystemVolumeView()
                        .frame(height: 44)
                        .frame(height: layout.volume)
                        .accessibilityLabel("音量")
                    bottomControls.frame(height: layout.bottom)
                }
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        .frame(idealWidth: 560, maxWidth: .infinity, idealHeight: 800)
        .background(.background)
        .task(id: player.currentItem?.id) {
            isScrubbing = false
            favoriteTrack = player.currentItem
            guard let id = player.currentItem?.id, let client = auth.client else { return }
            if let item = try? await client.fetchItem(id: id), !Task.isCancelled {
                favoriteTrack = item
            }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.down").font(.headline)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("プレイヤーを閉じる")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func mediaContent(width: CGFloat, height: CGFloat) -> some View {
        switch mode {
        case .artwork:
            ArtworkView(item: player.currentItem, size: max(1, min(width, height - 16)), cornerRadius: 16)
                .scaleEffect(reduceMotion || player.isPlaying ? 1 : 0.9)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: player.isPlaying)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .lyrics:
            if let track = player.currentItem {
                LyricsView(track: track)
                    .id(track.id)
            }
        case .queue:
            QueueView()
        }
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentItem?.displayName ?? "再生していません")
                    .font(.title2.bold())
                    .lineLimit(2)
                if let artist = player.currentItem?.displayArtist {
                    Text(artist).font(.body).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await toggleFavorite() }
            } label: {
                Image(systemName: favoriteTrack?.isFavorite == true ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(favoriteTrack?.isFavorite == true ? Color.accentColor : .primary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .disabled(favoriteTrack == nil || isUpdatingFavorite)
            .accessibilityLabel(favoriteTrack?.isFavorite == true ? "お気に入りから削除" : "お気に入りに追加")
        }
    }

    private var seekControls: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { min(max(isScrubbing ? scrubTime : player.currentTime, 0), max(player.duration, 1)) },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing { scrubTime = player.currentTime } else { player.seek(to: scrubTime) }
                    isScrubbing = editing
                }
            )
            .disabled(player.duration <= 0)
            .accessibilityLabel("再生位置")
            .accessibilityValue(player.currentTime.timeLabel)
            .accessibilityAdjustableAction { direction in
                guard player.duration > 0 else { return }
                switch direction {
                case .increment: player.seek(to: player.currentTime + 10)
                case .decrement: player.seek(to: player.currentTime - 10)
                @unknown default: break
                }
            }
            HStack {
                Text((isScrubbing ? scrubTime : player.currentTime).timeLabel)
                Spacer()
                Text(max(0, player.duration - (isScrubbing ? scrubTime : player.currentTime)).remainingLabel)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 32) {
            Button {
                player.playPrevious()
            } label: {
                Image(systemName: "backward.fill").font(.title)
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel("前の曲")
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .frame(width: 64, height: 64)
                    .overlay(alignment: .bottom) {
                        if player.isBuffering { ProgressView().controlSize(.mini) }
                    }
            }
            .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
            Button {
                player.playNext()
            } label: {
                Image(systemName: "forward.fill").font(.title)
                    .frame(width: 52, height: 52)
            }
            .disabled(!player.hasNext)
            .accessibilityLabel("次の曲")
        }
        .buttonStyle(.plain)
        .disabled(player.currentItem == nil)
        .frame(maxWidth: .infinity)
    }

    private var bottomControls: some View {
        HStack {
            modeButton(.lyrics, symbol: "quote.bubble", label: "歌詞")
            Spacer()
            AudioRouteView().frame(width: 44, height: 44)
                .accessibilityLabel("出力先")
            Spacer()
            modeButton(.queue, symbol: "list.bullet", label: "次に再生")
        }
        .padding(.horizontal, 16)
    }

    private func modeButton(_ target: ContentMode, symbol: String, label: String) -> some View {
        Button {
            mode = mode == target ? .artwork : target
        } label: {
            Image(systemName: symbol).font(.title3)
                .frame(width: 44, height: 44)
                .foregroundStyle(mode == target ? Color.accentColor : .primary)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
        .accessibilityAddTraits(mode == target ? .isSelected : [])
    }

    private func toggleFavorite() async {
        guard let track = favoriteTrack else { return }
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }
        await library.toggleFavorite(track)
        // 再生キューの値は更新されないため、サーバーの確定値を表示に反映する。
        guard let client = auth.client,
            let updated = try? await client.fetchItem(id: track.id),
            player.currentItem?.id == track.id
        else { return }
        favoriteTrack = updated
    }
}

private struct PlayerLayout {
    let top: CGFloat
    let media: CGFloat
    let title: CGFloat
    let seek: CGFloat
    let transport: CGFloat
    let volume: CGFloat
    let bottom: CGFloat
    var total: CGFloat { top + media + title + seek + transport + volume + bottom }

    init(height: CGFloat, titleMinimum: CGFloat, seekMinimum: CGFloat) {
        top = max(44, height * 0.07)
        title = max(titleMinimum, height * 0.12)
        seek = max(seekMinimum, height * 0.08)
        transport = max(64, height * 0.13)
        volume = max(44, height * 0.08)
        bottom = max(52, height * 0.09)
        // 操作部の最小寸法を先に守り、収まらない場合だけ全体をスクロールさせる。
        media = max(96, height - top - title - seek - transport - volume - bottom)
    }
}

private struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        // 出力先は下部の AVRoutePickerView に集約するため、標準のルートボタンを隠す。
        view.showsRouteButton = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct AudioRouteView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
