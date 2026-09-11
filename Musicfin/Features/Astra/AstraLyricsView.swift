import SwiftUI

/// 読む位置を安定させるため、強調は文字の濃淡に留め、行の大きさを変えない。
struct AstraLyricsView: View {
    let track: MediaItem
    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lines: [LyricLine] = []
    @State private var isLoading = true
    @State private var isFollowing = true
    @State private var errorMessage: String?

    private var isSynced: Bool { lines.contains { $0.startSeconds != nil } }
    private var activeIndex: Int? {
        lines.lastIndex { ($0.startSeconds ?? .infinity) <= player.currentTime }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("歌詞を読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ScrollView {
                    AstraLibraryLoadError(message: errorMessage) { await load() }
                }
            } else if lines.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        Text("歌詞がありません").font(.headline)
                        Text("この曲には歌詞が登録されていません。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                lyricsList
            }
        }
        .task(id: track.id) { await load() }
    }

    private var lyricsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Group {
                            if let start = line.startSeconds {
                                Button {
                                    player.seek(to: start)
                                } label: {
                                    lineText(line, active: index == activeIndex)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("この行の再生位置へ移動")
                                .accessibilityAddTraits(index == activeIndex ? .isSelected : [])
                            } else {
                                lineText(line, active: !isSynced)
                            }
                        }
                        .id(index)
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                // 自動追従のアニメーションでは止めず、ユーザーが触れた時点で読む位置を尊重する。
                if phase == .tracking || phase == .interacting { isFollowing = false }
            }
            .onChange(of: activeIndex, initial: true) { _, index in
                guard isFollowing, let index else { return }
                scroll(to: index, proxy: proxy)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSynced, !isFollowing {
                    Button("現在位置へ") {
                        isFollowing = true
                        scroll(to: activeIndex ?? 0, proxy: proxy)
                    }
                    .buttonStyle(.glass)
                    .frame(minHeight: 44)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func lineText(_ line: LyricLine, active: Bool) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(active ? .primary : .secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
    }

    private func scroll(to index: Int, proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    private func load() async {
        isLoading = true
        isFollowing = true
        errorMessage = nil
        lines = []
        defer { if !Task.isCancelled { isLoading = false } }
        guard let client = auth.client else {
            errorMessage = "サーバーに接続してから、もう一度お試しください。"
            return
        }
        do {
            let fetched = try await client.fetchLyrics(itemID: track.id) ?? []
            try Task.checkCancellation()
            lines = fetched.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? fetched : []
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

#Preview {
    AstraLyricsView(track: MediaItem(id: "preview-track", name: "夜の散歩", type: .audio))
        .environment(AuthStore())
        .environment(PlaybackEngine())
        .frame(height: 320)
        .padding()
}
