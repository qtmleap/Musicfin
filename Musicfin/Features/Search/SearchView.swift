import SwiftUI

/// 曲・アルバム・アーティスト・プレイリストを横断して検索する。
struct SearchView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackEngine.self) private var player

    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if !tracks.isEmpty { section("曲", items: tracks) }
            if !albums.isEmpty { section("アルバム", items: albums) }
            if !artists.isEmpty { section("アーティスト", items: artists) }
            if !playlists.isEmpty { section("プレイリスト", items: playlists) }
        }
        .listStyle(.plain)
        .navigationTitle("検索")
        .searchable(text: $query, prompt: "曲、アルバム、アーティスト")
        .overlay { emptyState }
        .onChange(of: query) { _, newValue in scheduleSearch(for: newValue) }
        .navigationDestination(for: MediaItem.self) { destination(for: $0) }
    }

    // MARK: - 種類ごとの絞り込み

    private var tracks: [MediaItem] { results.filter { $0.type == .audio } }
    private var albums: [MediaItem] { results.filter { $0.type == .musicAlbum } }
    private var artists: [MediaItem] { results.filter { $0.type == .musicArtist } }
    private var playlists: [MediaItem] { results.filter { $0.type == .playlist } }

    @ViewBuilder
    private func section(_ title: String, items: [MediaItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                if item.type == .audio {
                    Button {
                        // 検索結果の曲は、同じ種別の結果をまとめてキューに入れる。
                        if let index = tracks.firstIndex(where: { $0.id == item.id }) {
                            player.play(items: tracks, startingAt: index)
                        }
                    } label: {
                        TrackRow(track: item, showsArtwork: true, isPlaying: player.currentItem?.id == item.id)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: item) {
                        if item.type == .musicArtist {
                            ArtistRow(artist: item)
                        } else {
                            containerRow(item)
                        }
                    }
                }
            }
        }
    }

    private func containerRow(_ item: MediaItem) -> some View {
        HStack(spacing: 12) {
            ArtworkView(item: item, size: 52, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).lineLimit(1)
                if let subtitle = item.albumArtist ?? item.displayArtist {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for item: MediaItem) -> some View {
        if item.type == .musicArtist {
            ArtistDetailView(artist: item)
        } else {
            AlbumDetailView(album: item)
        }
    }

    // MARK: - 状態表示

    @ViewBuilder
    private var emptyState: some View {
        if query.isEmpty {
            ContentUnavailableView(
                "ライブラリを検索",
                systemImage: "magnifyingglass",
                description: Text("曲名、アルバム名、アーティスト名で探せます。")
            )
        } else if isSearching, results.isEmpty {
            ProgressView()
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: - 検索の実行

    /// 入力のたびに投げると負荷が高いので 300ms のデバウンスをかける。
    private func scheduleSearch(for term: String) {
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let client = auth.client else { return }
            let found = (try? await client.search(term: trimmed).items) ?? []
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}
