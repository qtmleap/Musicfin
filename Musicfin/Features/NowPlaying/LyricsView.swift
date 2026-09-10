import SwiftUI

/// 時間同期歌詞。現在の行を強調し、再生に合わせて自動スクロールする。
struct LyricsView: View {
    let track: MediaItem

    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackEngine.self) private var player

    @State private var lines: [LyricLine] = []
    @State private var state: LoadState = .loading
    /// ユーザーが手で動かした直後は自動スクロールを止める。
    @State private var isUserScrolling = false
    @State private var resumeScrollTask: Task<Void, Never>?

    private enum LoadState { case loading, ready, unavailable }

    /// 同期歌詞かどうか。時間情報が無い場合は単なるテキスト表示にする。
    private var isSynced: Bool { lines.contains { $0.startSeconds != nil } }

    /// 現在再生位置に対応する行の番号。
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
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        lineView(line, isActive: index == activeIndex)
                            .id(index)
                            .onTapGesture {
                                // 行タップでその位置へシーク（同期歌詞のときだけ）。
                                guard let start = line.startSeconds else { return }
                                player.seek(to: start)
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                guard phase == .interacting else { return }
                pauseAutoScroll()
            }
            .onChange(of: activeIndex) { _, index in
                guard let index, !isUserScrolling else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private func lineView(_ line: LyricLine, isActive: Bool) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.title3.weight(isActive ? .bold : .semibold))
            .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .scaleEffect(isActive ? 1.0 : 0.96, anchor: .leading)
            .animation(.easeOut(duration: 0.25), value: isActive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }

    /// 手動スクロール後 4 秒間は追従を止め、その後自動的に再開する。
    private func pauseAutoScroll() {
        isUserScrolling = true
        resumeScrollTask?.cancel()
        resumeScrollTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            isUserScrolling = false
        }
    }

    private func load() async {
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
