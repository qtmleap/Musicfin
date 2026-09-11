import SwiftUI

/// 人物の識別を円形画像に任せ、作品一覧は他画面と同じ余白・列幅で揃える。
struct AstraArtistDetailView: View {
    let artist: MediaItem
    @Environment(AuthStore.self) private var auth
    @State private var albums: [MediaItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedAlbum: MediaItem?

    var body: some View {
        GeometryReader { geometry in
            let metrics = AstraAlbumGridMetrics(width: geometry.size.width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 16) {
                        ArtworkView(item: artist, size: min(160, max(1, geometry.size.width - 32)), cornerRadius: 80)
                            .accessibilityHidden(true)
                        Text(artist.displayName)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .frame(maxWidth: .infinity)
                    if isLoading {
                        ProgressView("アルバムを読み込み中…").frame(maxWidth: .infinity)
                    } else if let errorMessage {
                        AstraLibraryLoadError(message: errorMessage) { await load() }
                    } else if albums.isEmpty {
                        ContentUnavailableView("アルバムがありません", systemImage: "square.stack")
                    } else {
                        Text("アルバム")
                            .font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 24) {
                            ForEach(albums) { album in
                                Button {
                                    selectedAlbum = album
                                } label: {
                                    AstraAlbumCard(item: album, size: metrics.size, showsSubtitle: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(artist.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedAlbum) { AstraAlbumDetailView(album: $0) }
        .task(id: artist.id) { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let client = auth.client else {
            errorMessage = "サーバーに接続してから、もう一度お試しください。"
            return
        }
        do {
            let result = try await client.fetchAlbums(byArtist: artist.id)
            try Task.checkCancellation()
            albums = result.items
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

#Preview {
    NavigationStack {
        AstraArtistDetailView(artist: MediaItem(id: "preview-artist", name: "アーティスト", type: .musicArtist))
    }
    .environment(AuthStore())
    .environment(PlaybackEngine())
}
