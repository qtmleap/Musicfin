import SwiftUI

/// 読む位置を安定させるため、強調は文字の濃淡に留め、行の大きさを変えない。
struct LyricsView: View {
    let track: MediaItem
    /// 上部の切り替えが終わっているか（仕様 5.1 章）。false の間は初回の位置合わせを保留する。
    var isSettled = true

    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackEngine.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 比較用の暫定値（仕様 5.2 章）。**Apple 実機の実測値ではない。**
    /// 固定値や `.custom` にせず `@ScaledMetric` に持たせるのは、Dynamic Type へ追従させるため。
    @ScaledMetric(relativeTo: .title) private var lyricSize = 32.0
    @ScaledMetric(relativeTo: .title) private var lyricSpacing = 12.0
    @State private var lines: [LyricLine] = []
    @State private var isLoading = true
    @State private var isFollowing = true
    /// 初回の位置合わせを済ませたか。曲を読み直すまで一度だけ行う。
    @State private var hasAligned = false
    @State private var errorMessage: String?

    private var isSynced: Bool { lines.contains { $0.startSeconds != nil } }

    /// 現在行は「再生位置以下で開始時刻が最大の行」（仕様 5.2 章）。
    /// 以前の `lastIndex` は「配列の後ろほど新しい時刻」を前提にしていたが、
    /// 並びは取得元の都合で、時刻順である保証がない。順序に寄りかからず最大値で選ぶ。
    private func activeIndex(at time: TimeInterval) -> Int? {
        var best: Int?
        var bestStart = -TimeInterval.infinity
        for (index, line) in lines.enumerated() {
            guard let start = line.startSeconds, start <= time, start >= bestStart else { continue }
            best = index
            bestStart = start
        }
        return best
    }

    /// 再生位置と現在行は **`body` の評価時にここで一度だけ読む**（仕様 5.2 章）。
    /// 各行のクロージャの中で `player.currentTime` を読むと、行の再評価が `body` の観測から外れて
    /// 更新の届き方が構成に左右される。強調・選択状態・追従へは、必ずこの同じ値を配る。
    var body: some View {
        let active = activeIndex(at: player.currentTime)
        return Group {
            if isLoading {
                ProgressView("歌詞を読み込み中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ScrollView {
                    LoadErrorView(message: errorMessage) { await load() }
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
                lyricsList(activeIndex: active)
            }
        }
        .task(id: track.id) { await load() }
    }

    private func lyricsList(activeIndex active: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: lyricSpacing) {
                    // 時刻の無い歌詞では現在行が決まらない。全行を強調して「どれも現在行」に見せるより、
                    // 追従できない歌詞だと先に断る（仕様 5.2 章）。時刻は作らない。
                    if !isSynced {
                        Text("この歌詞には時間情報がありません。再生に合わせた自動追従は行いません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Group {
                            if let start = line.startSeconds {
                                Button {
                                    player.seek(to: start)
                                } label: {
                                    lineText(line, active: index == active)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("この行の再生位置へ移動")
                                .accessibilityAddTraits(index == active ? .isSelected : [])
                            } else {
                                // 時刻が無ければ飛び先も無いので、押せる行にしない（仕様 5.2 章）。
                                lineText(line, active: false)
                            }
                        }
                        .id(index)
                    }
                }
                .padding(.vertical, 24)
                // 同じ画面の小アートワークや曲名と同じ左右 32 pt に載せる（仕様 5 章）。外側の 24 pt との差。
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                // 自動追従のアニメーションでは止めず、ユーザーが触れた時点で読む位置を尊重する。
                if phase == .tracking || phase == .interacting { isFollowing = false }
            }
            // **`isFollowing` が止めるのはスクロールだけ**（仕様 5.2 章）。過去の歌詞を手で読んでいる間も
            // 現在行の算出と強調は続くので、ここの `guard` は `scroll` の手前にしか置かない。
            .onChange(of: active) { _, index in
                guard hasAligned, isFollowing, let index else { return }
                scroll(to: index, proxy: proxy)
            }
            // 初回だけは上部の切り替えが終わってから合わせる（仕様 5.1 章）。
            // 遷移中に動かすと、対応付けた画像と本文が別の速さで流れて二重に見える。
            .onChange(of: isSettled, initial: true) { _, settled in
                guard settled, !hasAligned else { return }
                hasAligned = true
                guard isFollowing, let active else { return }
                scroll(to: active, proxy: proxy)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSynced, !isFollowing {
                    Button("現在位置へ") {
                        isFollowing = true
                        scroll(to: active ?? 0, proxy: proxy)
                    }
                    .buttonStyle(.glass)
                    .frame(minHeight: 44)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// 全行で同じ大きさ・同じウェイトにする。現在行だけ大きくすると行高が変わり、
    /// 追従のたびに前後の行が動いて読む位置を見失う（ファイル冒頭の方針・仕様 5.2 章）。
    /// 濃淡は `.primary` / `.secondary` のまま。参照画像の非活性行にはぼかしが掛かっていて
    /// 不透明度を逆算できないので、**未計測の係数やぼかしは足さない**。
    /// 段内に `lineSpacing` を足さないのも同じ理由で、項目間隔だけで間を作る。
    private func lineText(_ line: LyricLine, active: Bool) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: lyricSize, weight: .bold))
            .foregroundStyle(active ? .primary : .secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // 44 pt はタップ領域の下限。文字が大きくなれば行の高さはそちらに従って伸びる。
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
        hasAligned = false
        errorMessage = nil
        lines = []
        defer { if !Task.isCancelled { isLoading = false } }
        guard let client = auth.client else {
            errorMessage = String(localized: "サーバーに接続してから、もう一度お試しください。")
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
    LyricsView(track: MediaItem(id: "preview-track", name: "夜の散歩", type: .audio))
        .environment(AuthStore())
        .environment(PlaybackEngine())
        .frame(height: 320)
        .padding()
}
