import SwiftUI

/// ミニプレイヤー。`tabViewBottomAccessory` に置き、`.expanded` / `.inline` で密度を変える（`docs/ui-spec.md` 3 章）。
/// ガラスの帯の上に塗りを重ねず、Apple Music と同じく裸のグリフだけを並べる。
struct MiniPlayerView: View {
    /// 自分の矩形（窓座標）が変わったときに知らせる。フルプレイヤーを「ここから展開する」方式が
    /// 出発・帰着に使う（仕様 4.1.1 章）。既定を空にしてあるのは、矩形を要らない呼び出し側のため。
    var onFrameChange: (CGRect) -> Void = { _ in }
    let openPlayer: () -> Void

    @Environment(PlaybackEngine.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        if let track = player.currentItem {
            // 間隔 0 は、一時停止と次曲の記号の空きを Apple 実機の実測 26 pt に合わせるため。
            // 44 pt の当たり判定は両方のボタンで維持する。詰めた分は曲名ボタンが吸収する。
            HStack(spacing: 0) {
                Button(action: openPlayer) {
                    // 画像の右端から曲名までは 8 pt（仕様 3 章）。画像側に余白を足して広げない。
                    HStack(spacing: 8) {
                        artwork(for: track)
                        VStack(alignment: .leading, spacing: 2) {
                            // 2 段目だけ小さくせず、濃淡とウェイトで主従を付ける（仕様 3 章）。
                            Text(track.displayName)
                                .font(.subheadline.weight(.medium))
                            if !isInline {
                                Text(track.displayArtist ?? String(localized: "不明なアーティスト"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // 入らない分は末尾を省略する。フルプレイヤーと同じ扱いに揃える（仕様 3 章・4 章）。
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                        // 仕様 3 章の約 18 pt は再生・一時停止の指定。次曲は Apple 実機の実測が
                        // 24×14 pt と一回り小さいので、字送り 14 pt（横長の記号なので幅は約 24 pt）にする。
                        Image(systemName: "forward.fill")
                            .font(.system(size: 14, weight: .medium))
                            // 裸のグリフなので、透明な余白まで押せることを形で明示する。
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasNext)
                    .accessibilityLabel("次の曲")
                }
            }
            // 左だけ 4 pt 内側へ寄せて画像を Apple 実機と同じ位置に置く。帯そのものは狭めない。
            // 右は 14 pt。帯・画像・曲名の字面左端は Apple 実機と一致しているのに、一時停止と次送りの
            // 中心だけが 2.0 / 2.67 pt 右に寄っていたので、2 点の中間を取って 2 pt だけ内側へ動かす（仕様 3 章）。
            .padding(.leading, isInline ? 8 : 16)
            .padding(.trailing, isInline ? 8 : 14)
            .padding(.vertical, isInline ? 0 : 8)
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
            // 報告するのは**この行の矩形**で、ガラスの帯そのものではない。帯は
            // `tabViewBottomAccessory` が UIKit 側で持っており SwiftUI から測れないので、
            // 内側の余白まで含めたこの矩形を帯の代わりに使う（数 pt 内側に入る）。
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                onFrameChange($0)
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
