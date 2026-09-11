import SwiftUI

/// 曲・アルバム・アーティスト・プレイリストを横断して検索する。
/// 入力前は空白にせず、ジャンルのチップとアーティスト一覧を出して「たどって探す」入口にする（iPod の Browse 相当）。
struct FableSearchView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(AlbumCatalog.self) private var catalog
    @Environment(PlaybackEngine.self) private var player

    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isLoadingBrowse = true
    /// チップは `List` の 1 行に横並びで入れるので、行全体がリンクにならないよう遷移はこちらで行う。
    @State private var selectedGenre: String?

    private var isQueryEmpty: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            if isQueryEmpty {
                browseSections
            } else {
                if !tracks.isEmpty { section("曲", items: tracks) }
                if !albums.isEmpty { section("アルバム", items: albums) }
                if !artists.isEmpty { section("アーティスト", items: artists) }
                if !playlists.isEmpty { section("プレイリスト", items: playlists) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FableBackdrop())
        .navigationTitle("検索")
        .searchable(text: $query, prompt: "曲、アルバム、アーティスト")
        .overlay { emptyState }
        .onChange(of: query) { _, newValue in scheduleSearch(for: newValue) }
        .navigationDestination(item: $selectedGenre) { genre in
            FableAlbumGridView(title: genre, albums: catalog.albums(in: genre))
        }
        .task { await loadBrowse() }
    }

    // MARK: - 入力前のブラウズ

    @ViewBuilder
    private var browseSections: some View {
        if catalog.isComplete, !catalog.genres.isEmpty {
            Section("ジャンルから探す") {
                genreChips
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        if !library.artists.isEmpty {
            Section("アーティスト") {
                ForEach(library.artists) { artist in
                    NavigationLink {
                        FableArtistDetailView(artist: artist)
                    } label: {
                        FableArtistRow(artist: artist)
                    }
                }
            }
        }
    }

    /// ジャンルは件数が読めないので、縦に積まず横スクロールのチップにして一覧の高さを固定する。
    private var genreChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(catalog.genres, id: \.self) { genre in
                    Button {
                        selectedGenre = genre
                    } label: {
                        Text(genre)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
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
                        FableTrackRow(track: item, showsArtwork: true, isPlaying: player.currentItem?.id == item.id)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        destination(for: item)
                    } label: {
                        if item.type == .musicArtist {
                            FableArtistRow(artist: item)
                        } else {
                            FableContainerRow(item: item)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for item: MediaItem) -> some View {
        if item.type == .musicArtist {
            FableArtistDetailView(artist: item)
        } else {
            FableAlbumDetailView(album: item)
        }
    }

    // MARK: - 状態表示

    @ViewBuilder
    private var emptyState: some View {
        if isQueryEmpty {
            if isLoadingBrowse, library.artists.isEmpty {
                ProgressView()
            } else if library.artists.isEmpty, catalog.genres.isEmpty {
                ContentUnavailableView(
                    "ライブラリを検索",
                    systemImage: "magnifyingglass",
                    description: Text("曲名、アルバム名、アーティスト名で探せます。")
                )
            }
        } else if isSearching, results.isEmpty {
            ProgressView()
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }

    // MARK: - 読み込みと検索

    /// ブラウズ用の材料。ジャンルは全アルバムを読み切らないと確定しないので、ここで残りのページも取り切る。
    private func loadBrowse() async {
        guard let client = auth.client else { return }
        async let artists: Void = library.loadArtists()
        async let albums: Void = catalog.loadAll { try await client.fetchAlbums(startIndex: $0) }
        _ = await (artists, albums)
        isLoadingBrowse = false
    }

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

#Preview {
    NavigationStack {
        FableSearchView()
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
    .environment(AlbumCatalog())
}
