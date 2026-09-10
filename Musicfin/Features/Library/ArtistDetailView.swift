import SwiftUI

/// アーティストのアルバム一覧。
struct ArtistDetailView: View {
    let artist: MediaItem

    @Environment(LibraryStore.self) private var library
    @State private var albums: [MediaItem] = []
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ArtworkView(item: artist, size: 160, cornerRadius: 80)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .padding(.top, 8)

                Text(artist.displayName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                if isLoading {
                    ProgressView().padding(.top, 40)
                } else if albums.isEmpty {
                    ContentUnavailableView("アルバムがありません", systemImage: "square.stack")
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumCard(item: album, size: 150, showsSubtitle: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(artist.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albums = await library.albums(byArtist: artist)
            isLoading = false
        }
    }
}
