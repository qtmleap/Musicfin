import SwiftUI

/// アーティストのアルバム一覧。円形のアートワークを見出しにして、下にアルバムをグリッドで並べる。
struct ArtistDetailView: View {
    let artist: MediaItem

    @Environment(LibraryStore.self) private var library
    @State private var albums: [MediaItem] = []
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geometry in
            let metrics = AlbumGridMetrics(width: geometry.size.width)
            ScrollView {
                VStack(spacing: 20) {
                    ArtworkView(item: artist, size: 160, cornerRadius: 80)
                        .overlay(Circle().strokeBorder(.pink.opacity(0.35), lineWidth: 2))
                        .shadow(color: .pink.opacity(0.25), radius: 18, y: 8)
                        .padding(.top, 8)

                    VStack(spacing: 4) {
                        Text(artist.displayName)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        if !isLoading, !albums.isEmpty {
                            Text("\(albums.count) 枚のアルバム")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 24)

                    if isLoading {
                        ProgressView().padding(.top, 40)
                    } else if albums.isEmpty {
                        ContentUnavailableView("アルバムがありません", systemImage: "square.stack")
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: 24) {
                            ForEach(albums) { album in
                                NavigationLink {
                                    AlbumDetailView(album: album)
                                } label: {
                                    // 同じアーティストの一覧なので、サブタイトルは名前の繰り返しではなく年にする。
                                    AlbumCard(
                                        item: album, size: metrics.size,
                                        subtitle: album.productionYear.map(String.init) ?? "")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
        }
        .background(AppBackdrop())
        .navigationTitle(artist.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albums = await library.albums(byArtist: artist)
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        ArtistDetailView(artist: MediaItem(id: "preview", name: "Preview Artist", type: .musicArtist))
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
}
