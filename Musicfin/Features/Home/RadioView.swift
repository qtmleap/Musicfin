import SwiftUI

/// 実在するライブラリ項目を種に Jellyfin の Instant Mix を表示する。
struct RadioView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var mix: [MediaItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("ステーションを作成中…")
                    .accessibilityIdentifier("radio.loading")
            } else if let errorMessage {
                LoadErrorView(message: errorMessage) { await refresh() }
                    .accessibilityIdentifier("radio.error")
            } else if mix.isEmpty {
                ContentUnavailableView(
                    "再生できるステーションがありません",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text("ライブラリに音楽を追加すると、ステーションを作成できます。")
                )
                .accessibilityIdentifier("radio.empty")
            } else {
                List(Array(mix.enumerated()), id: \.element.id) { index, track in
                    Button {
                        player.play(items: mix, startingAt: index)
                    } label: {
                        TrackRow(track: track, showsArtwork: true, artworkSize: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("radio.track.\(track.id)")
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await refresh() }
            }
        }
        .background(AppBackdrop())
        .navigationTitle("ラジオ")
        .navigationBarTitleDisplayMode(.large)
        .task { await loadHomeAndMix() }
    }

    private func loadHomeAndMix() async {
        await library.loadHome()
        await load()
    }

    private func refresh() async {
        await library.loadHome(force: true)
        await load()
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 再生実績を優先し、履歴が無い場合だけ実在するライブラリ項目へフォールバックする。
        guard
            let seed = library.frequentlyPlayed.first ?? library.recentlyPlayedAlbums.first
                ?? library.recentlyAdded.first
        else {
            mix = []
            return
        }
        guard let client = auth.client else {
            mix = []
            return
        }
        do {
            mix = try await client.fetchInstantMix(from: seed.id, limit: 30)
                .filter { $0.type == .audio }
        } catch {
            mix = []
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { RadioView() }
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
}
