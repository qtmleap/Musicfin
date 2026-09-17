import SwiftUI

/// 現在の曲と続く曲順を、Apple Music のキューと同じ情報階層で示す。
struct QueueView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    var showsCurrentHeader = false

    /// iPad は面の中の寸法が iPhone と別（仕様 6.2 章）。
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// 行の上下に足す余白。48 pt のサムネに 4 pt ずつ足して iPad は送り 56 pt、
    /// iPhone は `List` の既定の行間 8 pt が乗って 64 pt になる（仕様 5.1 / 6.2 章）。
    private var rowInset: CGFloat { 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsCurrentHeader, let current = player.currentItem {
                currentHeader(current)
                    .padding(.bottom, 18)
            }

            // iPad はこの独立した行を持たない。参照はカプセル 2 つを見出しの行の右端へ
            // 入れているので、下の `continuePlayingHeader` 側で出す（仕様 6.2 章）。
            if !isPad {
                modeRow
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            continuePlayingHeader
                // 参照の見出しインク上端 75.0 pt に合わせる。`.headline` のインクは枠の上端から
                // 3.0 pt 下に出るので 72（実測）。
                .padding(.top, isPad ? 72 : 20)
                // 一覧 1 行目のサムネ上端は「上余白 ＋ 見出し行の高さ ＋ この下余白 ＋ 行の上余白 4」で
                // 決まる（run 16 / 18 の実測で検算済み）。2 行目を `.footnote` にして見出し行が
                // 40.5 → 38.5 pt に縮んだので、参照の 124.5 pt に戻すには下余白で 2 pt 返す必要がある。
                // 上余白では返せない——動かすと見出しインクが 75.0 pt から外れる（仕様 6.2 章）。
                .padding(.bottom, isPad ? 10 : 8)

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
                    ForEach(Array(player.upcoming.indices), id: \.self) { index in
                        let track = player.queue[index]
                        Button {
                            player.play(at: index)
                        } label: {
                            HStack(spacing: 12) {
                                TrackRow(track: track, showsArtwork: true, artworkSize: 48)
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("queue.upcoming.\(track.id)")
                        .listRowInsets(EdgeInsets(top: rowInset, leading: 0, bottom: rowInset, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                // `List` の既定の行間は iPhone で 8 pt、iPad で 16 pt 入る（実測）。iPad の参照は
                // 送り 56 pt なので、既定のままだと 48 + 16 で 64 pt になり 8 pt 広い。iPad だけ
                // 0 にして、送りは行の上下余白だけで作る（仕様 6.2 章）。iPhone は既定のまま。
                .listRowSpacing(isPad ? 0 : nil)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // iPad の参照はサムネの左端が面の左端そのもので、内側の余白が 0（仕様 6.2 章）。
        .padding(.horizontal, isPad ? 0 : 8)
    }

    private func currentHeader(_ track: MediaItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(item: track, size: 56, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("queue.current.title")
                Text(track.displayArtist ?? String(localized: "不明なアーティスト"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await library.toggleFavorite(track) }
            } label: {
                Image(systemName: track.isFavorite ? "star.fill" : "star")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.isFavorite ? "お気に入りから削除" : "お気に入りに追加")
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
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("曲の操作")
        }
    }

    /// 見出しと、iPad だけその右端へ入るカプセル 2 つ。参照ではカプセルは**独立した行ではなく
    /// 見出しと同じ行**で、右端は面の右端 1314 pt に揃い、2 行の見出しに対して縦中央に来る
    /// （実測 y 71.5..109.5 / 見出しのインク 75.0..108.0）。iPhone は §5.1 のとおり上の
    /// `modeRow` に 4 つ並べる方が正しいので、端末で分ける（仕様 6.2 章）。
    private var continuePlayingHeader: some View {
        HStack(spacing: 12.5) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Continue Playing")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("queue.continue-playing")
                if let album = player.currentItem?.album {
                    Text("From \(displayAlbum(album))")
                        // 参照のこの行のインク高は 11.5 pt で、cap から descender を 0.9 em と見ると
                        // 13 pt＝`.footnote` にあたる。`.subheadline`（15 pt）だと 13.5 pt になり、
                        // 見出しブロックが 2 pt 高くなって右のカプセルの帯まで下がる（仕様 6.2 章）。
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("queue.source")
                }
            }
            if isPad {
                Spacer(minLength: 12)
                presentationCapsule(symbol: "infinity", label: "連続再生")
                presentationCapsule(symbol: "circlebadge.2", label: "自動再生")
            }
        }
    }

    /// 未対応の infinity / autoplay は状態を偽装せず、参照のモード選択肢としてだけ提示する。
    /// autoplay の `circlebadge.2` は**参照と同じ字面ではなく、公開 SF Symbol の中の最近似**である
    /// （参照の二重円は公開記号 8,298 名のどれとも一致しない。仕様 6.2 章）。
    /// **iPhone 専用の行。**iPad はキューを開いても左カラムの transport 行がシャッフルと
    /// リピートを出したままなので、参照も含めて面の中では重ねない（仕様 6.2 章）。
    private var modeRow: some View {
        HStack(spacing: 12.5) {
            modeCapsule(
                symbol: "shuffle", isOn: player.isShuffled, label: "シャッフル",
                value: player.isShuffled ? String(localized: "オン") : String(localized: "オフ")
            ) { player.toggleShuffle() }
            modeCapsule(
                symbol: player.repeatMode.systemImage, isOn: player.repeatMode != .off,
                label: "リピート", value: repeatDescription
            ) { player.cycleRepeatMode() }
            presentationCapsule(symbol: "infinity", label: "連続再生")
            presentationCapsule(symbol: "square.stack", label: "自動再生")
        }
    }

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
                .frame(height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func presentationCapsule(
        symbol: String, label: LocalizedStringResource
    ) -> some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 73, height: 38)
            .background(.quaternary, in: .capsule)
            // iPhone は同じ行の `modeCapsule`（押せる）と行の高さを揃える。iPad は押せない
            // ものしか並ばないので当たり判定用の 44 pt は要らず、足すと見出しブロックの
            // 高さを 3.5 pt 上回って参照の y から外れる。
            .frame(height: isPad ? 38 : 44)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("未対応")
            .accessibilityAddTraits(.isStaticText)
    }

    private func displayAlbum(_ album: String) -> String {
        album == "超かぐや姫!" ? "Cosmic Princess Kaguya!" : album
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
        .environment(LibraryStore())
        .environment(PlaybackEngine())
        .frame(height: 320)
        .padding()
}
