import SwiftUI

/// 曲順と再生方式だけを示し、未対応の編集操作を連想させるハンドルは置かない。
struct QueueView: View {
    @Environment(PlaybackEngine.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("次に再生")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    player.toggleShuffle()
                } label: {
                    Image(systemName: "shuffle").frame(width: 44, height: 44)
                }
                .foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .accessibilityLabel("シャッフル")
                .accessibilityValue(player.isShuffled ? "オン" : "オフ")
                .accessibilityAddTraits(player.isShuffled ? .isSelected : [])
                Button {
                    player.cycleRepeatMode()
                } label: {
                    Image(systemName: player.repeatMode.systemImage).frame(width: 44, height: 44)
                }
                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .accessibilityLabel("リピート")
                .accessibilityValue(repeatDescription)
            }
            .buttonStyle(.plain)
            Divider()
            if player.upcoming.isEmpty {
                ScrollView {
                    Text("次に再生する曲はありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            } else {
                List {
                    // ID が同じ曲も別の再生位置として扱い、重複曲を飛ばさない。
                    ForEach(Array(player.upcoming.indices), id: \.self) { index in
                        let track = player.queue[index]
                        Button {
                            player.play(at: index)
                        } label: {
                            TrackRow(track: track, showsArtwork: true)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var repeatDescription: String {
        switch player.repeatMode {
        case .off: "オフ"
        case .all: "すべての曲"
        case .one: "1 曲"
        }
    }
}

#Preview {
    QueueView()
        .environment(AuthStore())
        .environment(PlaybackEngine())
        .frame(height: 320)
        .padding()
}
