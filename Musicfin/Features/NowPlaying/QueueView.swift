import SwiftUI

/// 「次に再生」— 現在の曲より後ろのキューを並べ替え・削除できる形で表示する。
struct QueueView: View {
    @Environment(PlaybackEngine.self) private var player

    var body: some View {
        List {
            if let current = player.currentItem {
                Section("再生中") {
                    TrackRow(track: current, showsArtwork: true, isPlaying: true)
                }
            }

            Section {
                if player.upcoming.isEmpty {
                    Text("次に再生する曲はありません")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(Array(player.upcoming.enumerated()), id: \.element.id) { offset, track in
                        Button {
                            // upcoming は currentIndex+1 から始まるスライスなので、その分を足して実位置にする。
                            player.play(at: player.currentIndex + 1 + offset)
                        } label: {
                            TrackRow(track: track, showsArtwork: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("次に再生")
                    Spacer()
                    shuffleAndRepeat
                }
            }
        }
        .listStyle(.plain)
    }

    private var shuffleAndRepeat: some View {
        HStack(spacing: 16) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? Color.accentColor : .secondary)
            }
            .accessibilityLabel("シャッフル")

            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode.systemImage)
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            }
            .accessibilityLabel("リピート")
        }
        .buttonStyle(.plain)
        .font(.body)
    }
}
