import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Fable 版フルプレイヤー。`.large` 固定の sheet に `docs/ui-spec.md` 4 章の高さ配分で並べる。
/// ログイン・設定と同じピンクのグラデーションを敷き、再生ボタンだけをピンクで塗って「主役」を一つにする。
struct FableNowPlayingView: View {
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
    /// キュー内の `MediaItem` はお気に入りの変更を追わないので、サーバーの確定値をここに持つ。
    @State private var favoriteTrack: MediaItem?
    @State private var isUpdatingFavorite = false

    var body: some View {
        GeometryReader { geometry in
            let layout = FablePlayerLayout(
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
                    volumeRow.frame(height: layout.volume)
                    bottomControls.frame(height: layout.bottom)
                }
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
        }
        // iPad では 560pt を目安にした中央の sheet にする（6 章）。
        .frame(idealWidth: 560, maxWidth: .infinity, idealHeight: 800)
        .background(backdrop)
        // sheet はタブの tint を引き継がないので、ここで改めてピンクに揃える。
        .tint(.pink)
        .task(id: player.currentItem?.id) {
            isScrubbing = false
            favoriteTrack = player.currentItem
            guard let id = player.currentItem?.id, let client = auth.client else { return }
            if let item = try? await client.fetchItem(id: id), !Task.isCancelled {
                favoriteTrack = item
            }
        }
    }

    /// ブラウズ画面より一段濃いピンクから始めて、sheet が「別のレイヤー」に見えるようにする。
    private var backdrop: some View {
        LinearGradient(
            colors: [Color.pink.opacity(0.22), Color.pink.opacity(0.06), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - 上部

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.down")
                .font(.headline)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("プレイヤーを閉じる")
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - アートワーク / 歌詞 / キュー

    /// 切り替わるのはこの領域だけ。曲名以下の位置は動かさない（5 章）。
    @ViewBuilder
    private func mediaContent(width: CGFloat, height: CGFloat) -> some View {
        switch mode {
        case .artwork:
            ArtworkView(item: player.currentItem, size: max(1, min(width, height - 24)), cornerRadius: 20)
                // 停止中は 90% に縮めて「止まっている」ことを形で示す。視差効果を減らす設定なら固定。
                .scaleEffect(reduceMotion || player.isPlaying ? 1 : 0.9)
                .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: player.isPlaying)
                .shadow(color: .pink.opacity(0.3), radius: 28, y: 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .lyrics:
            if let track = player.currentItem {
                panel {
                    FableLyricsView(track: track)
                        .id(track.id)
                }
            }
        case .queue:
            panel { FableQueueView() }
        }
    }

    /// 歌詞・キューはアートワークと同じ枠に収まるガラスのカードに載せ、背景のグラデーションと切り分ける。
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
            .padding(.vertical, 12)
    }

    // MARK: - タイトル行

    private var titleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentItem?.displayName ?? "再生していません")
                    .font(.title2.bold())
                    .lineLimit(2)
                if let artist = player.currentItem?.displayArtist {
                    Text(artist)
                        .font(.body)
                        .foregroundStyle(.pink)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await toggleFavorite() }
            } label: {
                // ブラウズ画面と同じくお気に入りはハートで表す。
                Image(systemName: favoriteTrack?.isFavorite == true ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(favoriteTrack?.isFavorite == true ? AnyShapeStyle(.pink) : AnyShapeStyle(.primary))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .disabled(favoriteTrack == nil || isUpdatingFavorite)
            .accessibilityLabel(favoriteTrack?.isFavorite == true ? "お気に入りから削除" : "お気に入りに追加")
        }
    }

    // MARK: - シーク

    private var displayedTime: TimeInterval { isScrubbing ? scrubTime : player.currentTime }

    private var seekControls: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(
                    get: { min(max(displayedTime, 0), max(player.duration, 1)) },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    // ドラッグ中は表示だけ動かし、指を離したときに一度だけシークする。
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
                Text(displayedTime.timeLabel)
                Spacer()
                Text(max(0, player.duration - displayedTime).remainingLabel)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 再生操作

    private var transport: some View {
        HStack(spacing: 36) {
            Button {
                player.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前の曲")

            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.pink.gradient, in: .circle)
                    .shadow(color: .pink.opacity(0.35), radius: 12, y: 6)
                    .overlay(alignment: .bottom) {
                        if player.isBuffering {
                            ProgressView().controlSize(.mini).tint(.white).padding(.bottom, 8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")

            Button {
                player.playNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasNext)
            .accessibilityLabel("次の曲")
        }
        .disabled(player.currentItem == nil)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 音量

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            FableSystemVolumeView()
                .frame(height: 44)
                .accessibilityLabel("音量")
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - 下部（歌詞 / 出力先 / キュー）

    private var bottomControls: some View {
        GlassEffectContainer(spacing: 16) {
            HStack {
                modeButton(.lyrics, symbol: "quote.bubble", label: "歌詞")
                Spacer()
                FableAudioRouteView()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("出力先")
                Spacer()
                modeButton(.queue, symbol: "list.bullet", label: "次に再生")
            }
        }
        .padding(.horizontal, 16)
    }

    /// 選択中は prominent（ピンクで塗る）、それ以外は透明なガラスにして、どの領域を見ているかを形で示す。
    @ViewBuilder
    private func modeButton(_ target: ContentMode, symbol: String, label: String) -> some View {
        let isSelected = mode == target
        let icon = Image(systemName: symbol)
            .font(.title3)
            .frame(width: 44, height: 44)
        let action = { withAnimation(.snappy) { mode = isSelected ? .artwork : target } }
        if isSelected {
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

    private func toggleFavorite() async {
        guard let track = favoriteTrack else { return }
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }
        await library.toggleFavorite(track)
        guard let client = auth.client,
            let updated = try? await client.fetchItem(id: track.id),
            player.currentItem?.id == track.id
        else { return }
        favoriteTrack = updated
    }
}

/// 4 章の比率。操作部の最小寸法を先に守り、足りない分はアートワーク領域から削る。
private struct FablePlayerLayout {
    let top: CGFloat
    let media: CGFloat
    let title: CGFloat
    let seek: CGFloat
    let transport: CGFloat
    let volume: CGFloat
    let bottom: CGFloat

    init(height: CGFloat, titleMinimum: CGFloat, seekMinimum: CGFloat) {
        top = max(44, height * 0.07)
        title = max(titleMinimum, height * 0.12)
        seek = max(seekMinimum, height * 0.08)
        transport = max(72, height * 0.13)
        volume = max(44, height * 0.08)
        bottom = max(52, height * 0.09)
        media = max(96, height - top - title - seek - transport - volume - bottom)
    }
}

private struct FableSystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        // iOS 13 以降の MPVolumeView はスライダーだけなので、出力先は下部の AVRoutePickerView に任せる。
        MPVolumeView()
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct FableAudioRouteView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#Preview {
    FableNowPlayingView()
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
}
