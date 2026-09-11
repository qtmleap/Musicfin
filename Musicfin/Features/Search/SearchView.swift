import SwiftUI

/// 入力前にも探し方を示し、検索結果とブラウズを同じ素朴なリストでつなぐ。
struct SearchView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackEngine.self) private var player
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var retryGeneration = 0

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tracks: [MediaItem] { results.filter { $0.type == .audio } }

    var body: some View {
        List {
            if term.isEmpty {
                browse
            } else {
                resultsSection("曲", items: tracks)
                resultsSection("アルバム", items: results.filter { $0.type == .musicAlbum })
                resultsSection("アーティスト", items: results.filter { $0.type == .musicArtist })
                resultsSection("プレイリスト", items: results.filter { $0.type == .playlist })
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppBackdrop())
        .tint(.pink)
        .navigationTitle("検索")
        .searchable(text: $query, prompt: "曲、アルバム、アーティスト")
        .overlay { searchStatus }
        .onChange(of: query) { _, _ in
            // 古い語句の結果を新しい検索結果と誤認させないため、入力変更時に消す。
            results = []
            errorMessage = nil
            isSearching = !term.isEmpty
        }
        .task(id: [query, String(retryGeneration)]) { await search() }
    }

    private var browse: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("聴きたい音楽を探す")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("曲名、アルバム名、アーティスト名で検索できます。名前が浮かばないときは、ライブラリから。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 16)
            .listRowSeparator(.hidden)
            Section("ライブラリから探す") {
                NavigationLink {
                    LibraryCollectionView(kind: .artists)
                } label: {
                    Label("アーティスト", systemImage: "music.mic")
                        .frame(minHeight: 44)
                }
                NavigationLink {
                    GenreListView()
                } label: {
                    Label("ジャンル", systemImage: "guitars")
                        .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder
    private func resultsSection(_ title: String, items: [MediaItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    if item.type == .audio {
                        Button {
                            if let index = tracks.firstIndex(where: { $0.id == item.id }) {
                                player.play(items: tracks, startingAt: index)
                            }
                        } label: {
                            TrackRow(track: item, showsArtwork: true, isPlaying: player.currentItem?.id == item.id)
                        }
                        .buttonStyle(.plain)
                    } else if item.type == .musicArtist {
                        NavigationLink {
                            ArtistDetailView(artist: item)
                        } label: {
                            ArtistRow(artist: item)
                        }
                    } else {
                        NavigationLink {
                            AlbumDetailView(album: item)
                        } label: {
                            ContainerRow(item: item)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        if !term.isEmpty {
            if isSearching {
                ProgressView("検索中…")
            } else if let errorMessage {
                LoadErrorView(message: errorMessage) { retryGeneration += 1 }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: term)
            }
        }
    }

    private func search() async {
        let requestedTerm = term
        guard !requestedTerm.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        errorMessage = nil
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            // 入力のたびに通信せず、画面を離れた検索は task のキャンセルで破棄する。
            try await Task.sleep(for: .milliseconds(300))
            guard let client = auth.client else { throw JellyfinError.missingCredentials }
            let found = try await client.search(term: requestedTerm).items
            try Task.checkCancellation()
            guard term == requestedTerm else { return }
            results = found
        } catch {
            if !Task.isCancelled, term == requestedTerm { errorMessage = error.localizedDescription }
        }
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environment(AuthStore())
        .environment(PlaybackEngine())
        .environment(LibraryStore())
        .tint(.pink)
        .environment(AlbumCatalog())
}
