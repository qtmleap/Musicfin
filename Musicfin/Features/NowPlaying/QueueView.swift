import SwiftUI

/// 曲順と再生方式だけを示し、未対応の編集操作を連想させるハンドルは置かない。
struct QueueView: View {
    @Environment(PlaybackEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modeRow
            Text("次に再生")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                // 見出しの直下に罫線は引かず、縦の余白だけで区切る（仕様 5.2 章）。
                .padding(.top, 20)
                .padding(.bottom, 8)
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
                            // 既定の 44 pt はホームのお気に入り 3 段組の値。キューの行は他の一覧と同じ 48 pt。
                            TrackRow(track: track, showsArtwork: true, artworkSize: 48)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        // 行の地はアートワーク由来の背景の上に黒い帯として残る。以前は地が黒一色で
                        // 見えていなかっただけで、`scrollContentBackground` では行の地まで消えない（仕様 1.2 章）。
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 見出しも行も、アートワーク状態の曲名と同じ左右 32 pt に載る（仕様 5 章）。外側の 24 pt との差。
        .padding(.horizontal, 8)
    }

    /// 再生方式は見出し脇の裸アイコンではなく、独立した淡いカプセルに入れる（仕様 5.2 章）。
    private var modeRow: some View {
        HStack(spacing: 12) {
            modeCapsule(
                symbol: "shuffle",
                isOn: player.isShuffled,
                label: "シャッフル",
                value: player.isShuffled ? String(localized: "オン") : String(localized: "オフ"),
                action: { player.toggleShuffle() }
            )
            modeCapsule(
                symbol: player.repeatMode.systemImage,
                isOn: player.repeatMode != .off,
                label: "リピート",
                value: repeatDescription,
                action: { player.cycleRepeatMode() }
            )
        }
    }

    /// Apple 実機の実測どおり約 73×38 pt。オンだけアクセント色にし、地の濃さは変えない。
    private func modeCapsule(
        symbol: String,
        isOn: Bool,
        label: LocalizedStringResource,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 73, height: 38)
                .background(.quaternary, in: .capsule)
                // 見た目は 38 pt でも、当たり判定は 44 pt を確保する。
                .frame(height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var repeatDescription: String {
        switch player.repeatMode {
        case .off: String(localized: "オフ")
        case .all: String(localized: "すべての曲")
        case .one: String(localized: "1 曲")
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
