import SwiftUI

/// 実在するライブラリ項目を種に Jellyfin の Instant Mix を表示する。
struct RadioView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var catalog = RadioMixCatalog()
    private var mix: [MediaItem] { catalog.items }

    var body: some View {
        Group {
            if catalog.isLoading, mix.isEmpty {
                ProgressView("ステーションを作成中…")
                    .accessibilityIdentifier("radio.loading")
            } else if let errorMessage = catalog.errorMessage, mix.isEmpty {
                LoadErrorView(message: errorMessage) { await refresh() }
                    .accessibilityIdentifier("radio.error")
            } else if mix.isEmpty {
                VStack {
                    ContentUnavailableView(
                        "再生できるステーションがありません",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("ライブラリに音楽を追加すると、ステーションを作成できます。")
                    )
                    .accessibilityIdentifier("radio.empty")
                    if catalog.needsManualContinuation { continuation }
                }
            } else {
                List {
                    ForEach(Array(mix.enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.play(items: mix, startingAt: index)
                        } label: {
                            TrackRow(track: track, showsArtwork: true, artworkSize: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("radio.track.\(track.id)")
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    }
                    continuation
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await refresh() }
            }
        }
        .background(AppBackdrop())
        .tabNavigationTitle(Text("ラジオ"))
        .task(id: auth.client) {
            catalog.reset()
            await loadHomeAndMix()
        }
        .prefetchArtwork(mix, size: 48)
    }

    private func loadHomeAndMix() async {
        await library.loadHome()
        await load()
    }

    private func refresh() async {
        catalog.reset()
        await library.loadHome(force: true)
        await load()
    }

    @ViewBuilder
    private var continuation: some View {
        if let message = catalog.errorMessage {
            LoadErrorView(message: message) { await load() }
        } else if catalog.needsManualContinuation {
            Button("さらに読み込む") { Task { await load() } }
        } else if !catalog.isComplete {
            PaginationLoader(revision: mix.count, isLoading: { catalog.isLoading }, load: { await load() })
        }
    }

    private func load() async {
        guard let client = auth.client, let userID = client.userID else { return }
        await catalog.loadNext(
            preferredSeed: library.frequentlyPlayed.first ?? library.recentlyPlayedAlbums.first
                ?? library.recentlyAdded.first,
            fetchSeeds: { offset in
                try await client.get(
                    "/Items", query: LibraryFeed.recentlyAdded.query(userID: userID, startIndex: offset))
            },
            fetchMix: { try await client.fetchInstantMix(from: $0, limit: 30) }
        )
    }

}

#Preview {
    NavigationStack { RadioView() }
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
}
