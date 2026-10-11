import SwiftUI

/// ミニプレイヤー。`tabViewBottomAccessory` に置き、`.expanded` / `.inline` で密度を変える（`docs/ui-spec.md` 3 章）。
/// ガラスの帯の上に塗りを重ねず、Apple Music と同じく裸のグリフだけを並べる。
struct MiniPlayerView: View {
    /// 自分の矩形（窓座標）が変わったときに知らせる。フルプレイヤーを「ここから展開する」方式が
    /// 出発・帰着に使う（仕様 4.1.1 章）。既定を空にしてあるのは、矩形を要らない呼び出し側のため。
    var onFrameChange: (CGRect) -> Void = { _ in }
    /// iPad の detail 上では tab accessory の配置値を使わず、参照どおり 2 段表示へ固定する。
    var forceExpanded = false
    /// 歌詞・キューの右端ボタンから、開く先の表示を指定して開く。nil なら通常どおり開くだけに落とす。
    var openPlayerMode: ((NowPlayingView.ContentMode) -> Void)?
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

            // 右の 3 つは余白も押せるよう、40×44 の当たり判定を contentShape で明示する。
            MiniPlayerMenu(track: track)
            modeButton(.lyrics, symbol: "quote.bubble", identifier: "miniplayer.lyrics")
            modeButton(.queue, symbol: "list.bullet", identifier: "miniplayer.queue")
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 16)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            onFrameChange($0)
        }
    }

    private func modeButton(
        _ mode: NowPlayingView.ContentMode, symbol: String, identifier: String
    ) -> some View {
        Button {
            if let openPlayerMode { openPlayerMode(mode) } else { openPlayer() }
        } label: {
            Image(systemName: symbol)
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(mode == .lyrics ? String(localized: "歌詞") : String(localized: "再生待ち一覧"))
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
        .accessibilityIdentifier("miniplayer.next")
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

/// iPad の「…」。行のメニューと同じ操作を、いま再生中の曲へ向ける。
private struct MiniPlayerMenu: View {
    let track: MediaItem

    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player

    /// キュー内の `MediaItem` はお気に入りの変更を追わないので、サーバーの確定値を別に持つ。
    @State private var favoriteTrack: MediaItem?
    @State private var isUpdatingFavorite = false
    /// 初回取得が操作後に届いて、お気に入りの確定値を古い状態へ戻すのを防ぐ。
    @State private var favoriteGeneration = 0
    @State private var favoriteRefresh = 0
    private struct FavoriteRequest: Hashable {
        let trackID: String
        let refresh: Int
    }

    /// 曲が替わった直後に前の曲の状態でトグルしないよう、id が一致するときだけ採る。
    private var current: MediaItem {
        if let favoriteTrack, favoriteTrack.id == track.id { return favoriteTrack }
        return track
    }

    var body: some View {
        Menu {
            Button {
                player.playNext([track])
            } label: {
                Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                player.appendToQueue([track])
            } label: {
                Label("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button {
                Task { await toggleFavorite() }
            } label: {
                Label(
                    current.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                    systemImage: current.isFavorite ? "heart.slash" : "heart"
                )
            }
            .disabled(isUpdatingFavorite || favoriteTrack?.id != track.id)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityIdentifier("miniplayer.more")
        .accessibilityLabel("操作")
        .task(id: FavoriteRequest(trackID: track.id, refresh: favoriteRefresh)) {
            favoriteGeneration += 1
            let generation = favoriteGeneration
            favoriteTrack = nil
            guard let client = auth.client else { return }
            if let item = try? await client.fetchItem(id: track.id), !Task.isCancelled,
                favoriteGeneration == generation, player.currentItem?.id == track.id
            {
                favoriteTrack = item
            }
        }
    }

    private func toggleFavorite() async {
        guard let target = favoriteTrack, target.id == track.id, !isUpdatingFavorite else { return }
        favoriteGeneration += 1
        let generation = favoriteGeneration
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }
        await library.toggleFavorite(target)
        guard player.currentItem?.id == target.id, favoriteGeneration == generation else { return }
        if let client = auth.client, let updated = try? await client.fetchItem(id: target.id) {
            guard player.currentItem?.id == target.id, favoriteGeneration == generation else { return }
            favoriteTrack = updated
        } else {
            // 更新の結果を読めなければ古い値で再操作させず、初回と同じ取得経路へ戻す。
            guard player.currentItem?.id == target.id, favoriteGeneration == generation else { return }
            favoriteTrack = nil
            favoriteRefresh += 1
        }
    }
}

#Preview {
    Color.clear
        .tabViewBottomAccessory {
            MiniPlayerView {}
        }
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
}
