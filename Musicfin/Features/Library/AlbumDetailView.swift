import SwiftUI

/// アルバム／プレイリストの詳細。ヘッダーのアートワークと収録曲リスト。
struct AlbumDetailView: View {
    let album: MediaItem

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            } else {
                trackList
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await load() }
    }

    // MARK: - ヘッダー

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(item: album, size: 220, cornerRadius: 12)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

            VStack(spacing: 4) {
                Text(album.displayName)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                if let artist = album.albumArtist ?? album.displayArtist {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            playbackButtons
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let genre = album.genres?.first { parts.append(genre) }
        if let year = album.productionYear { parts.append("\(year)") }
        return parts.joined(separator: " · ")
    }

    private var playbackButtons: some View {
        HStack(spacing: 12) {
            Button {
                player.play(items: tracks)
            } label: {
                Label("再生", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }

            Button {
                // シャッフル再生はエンジン側の状態も合わせて切り替える。
                if !player.isShuffled { player.toggleShuffle() }
                player.play(items: tracks)
            } label: {
                Label("シャッフル", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.glassProminent)
        .disabled(tracks.isEmpty)
        .padding(.horizontal, 32)
        .padding(.top, 4)
    }

    // MARK: - 収録曲

    @ViewBuilder
    private var trackList: some View {
        let grouped = Dictionary(grouping: tracks) { $0.parentIndexNumber ?? 1 }
        let discs = grouped.keys.sorted()

        ForEach(discs, id: \.self) { disc in
            Section {
                ForEach(grouped[disc] ?? []) { track in
                    Button {
                        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
                            player.play(items: tracks, startingAt: index)
                        }
                    } label: {
                        TrackRow(track: track, isPlaying: player.currentItem?.id == track.id)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button {
                            player.playNext([track])
                        } label: {
                            Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await library.toggleFavorite(track) }
                        } label: {
                            Label("お気に入り", systemImage: track.isFavorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                }
            } header: {
                // ディスクが 1 枚だけならヘッダーは出さない。
                if discs.count > 1 {
                    Text("ディスク \(disc)")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    player.appendToQueue(tracks)
                } label: {
                    Label("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                Button {
                    player.playNext(tracks)
                } label: {
                    Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { await library.toggleFavorite(album) }
                } label: {
                    Label(
                        album.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                        systemImage: album.isFavorite ? "star.slash" : "star"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .disabled(tracks.isEmpty)
        }
    }

    private func load() async {
        tracks = await library.tracks(for: album)
        isLoading = false
    }
}
