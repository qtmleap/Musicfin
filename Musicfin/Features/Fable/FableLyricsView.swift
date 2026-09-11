import SwiftUI

/// Fable 版の歌詞領域。現在行をピンクで強調して追従し、読んでいる最中は追従を止める（`docs/ui-spec.md` 5 章）。
/// 取得経路は共通の `LyricsView` と同じ `client.fetchLyrics`。
struct FableLyricsView: View {
    let track: MediaItem

    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackEngine.self) private var player

    @State private var lines: [LyricLine] = []
    @State private var state: LoadState = .loading
    /// 読んでいる行を勝手に動かさないよう、「現在位置へ」で明示的に戻るまで追従を止める。
    @State private var isUserScrolling = false

    private enum LoadState { case loading, ready, unavailable }

    /// 同期歌詞かどうか。時間情報が無ければ追従もシークもしない、ただのテキストとして出す。
    private var isSynced: Bool { lines.contains { $0.startSeconds != nil } }

    private var activeIndex: Int? {
        guard isSynced else { return nil }
        let position = player.currentTime
        return lines.lastIndex { ($0.startSeconds ?? .infinity) <= position }
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                ContentUnavailableView(
                    "歌詞がありません",
                    systemImage: "quote.bubble",
                    description: Text("この曲にはサーバー上に歌詞が登録されていません。")
                )
            case .ready:
                lyricsList
            }
        }
        .task(id: track.id) { await load() }
    }

    private var lyricsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        lineView(line, isActive: index == activeIndex)
                            .id(index)
                            .onTapGesture {
                                guard let start = line.startSeconds else { return }
                                player.seek(to: start)
                            }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                guard phase == .interacting else { return }
                isUserScrolling = true
            }
            .onChange(of: activeIndex, initial: true) { _, index in
                guard let index, !isUserScrolling else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .overlay(alignment: .bottom) {
                if isSynced, isUserScrolling {
                    Button("現在位置へ", systemImage: "arrow.down.to.line") {
                        isUserScrolling = false
                        if let index = activeIndex {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func lineView(_ line: LyricLine, isActive: Bool) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.title3.weight(isActive ? .bold : .semibold))
            // 現在行だけをピンクにして、周りの行は薄くして視線を集める。
            .foregroundStyle(isActive ? AnyShapeStyle(.pink) : AnyShapeStyle(.tertiary))
            .scaleEffect(isActive ? 1.0 : 0.96, anchor: .leading)
            .animation(.easeOut(duration: 0.25), value: isActive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }

    private func load() async {
        isUserScrolling = false
        state = .loading
        guard let client = auth.client,
            let fetched = try? await client.fetchLyrics(itemID: track.id),
            !fetched.isEmpty
        else {
            state = .unavailable
            return
        }
        lines = fetched
        state = .ready
    }
}

#Preview {
    FableLyricsView(track: MediaItem(id: "preview", name: "Preview", type: .audio))
        .environment(AuthStore())
        .environment(PlaybackEngine())
}
