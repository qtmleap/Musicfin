import SwiftUI

/// 作品名と収録曲を読み取りやすくするため、アートワークの影や背景装飾を省く。
struct AstraAlbumDetailView: View {
    let album: MediaItem
    @Environment(AuthStore.self) private var auth
    @Environment(PlaybackEngine.self) private var player
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { geometry in
            List {
                header(width: geometry.size.width)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if isLoading {
                    ProgressView("収録曲を読み込み中…")
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                } else if let errorMessage {
                    AstraLibraryLoadError(message: errorMessage) { await load() }
                        .listRowSeparator(.hidden)
                } else if tracks.isEmpty {
                    ContentUnavailableView("曲がありません", systemImage: "music.note")
                        .listRowSeparator(.hidden)
                } else {
                    trackSections
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(album.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("その他", systemImage: "ellipsis") {
                    Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        player.playNext(tracks)
                    }
                    Button("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward") {
                        player.appendToQueue(tracks)
                    }
                }
                .disabled(isLoading || tracks.isEmpty)
            }
        }
        .task(id: album.id) { await load() }
    }

    private func header(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ArtworkView(item: album, size: max(1, min(240, width - 48)), cornerRadius: 8)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.displayName)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let artist = album.albumArtist ?? album.displayArtist {
                    Text(artist).font(.title3).foregroundStyle(.secondary)
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // 文字拡大時にもボタン名を省略せず、操作領域を縦に確保する。
            let layout =
                typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button {
                    if player.isShuffled { player.toggleShuffle() }
                    player.play(items: tracks)
                } label: {
                    Label("再生", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                Button {
                    if !player.isShuffled { player.toggleShuffle() }
                    player.play(items: tracks)
                } label: {
                    Label("シャッフル", systemImage: "shuffle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
            }
            .disabled(isLoading || tracks.isEmpty)
        }
        .padding(24)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        var parts = [String]()
        if let year = album.productionYear { parts.append(String(year)) }
        if let genre = album.genres?.first { parts.append(genre) }
        if !isLoading, errorMessage == nil { parts.append("\(tracks.count) 曲") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trackSections: some View {
        // プレイリストはディスク番号で並べ替えず、ユーザーが決めた順序を保つ。
        if album.type == .playlist {
            trackRows(Array(tracks.indices))
        } else {
            let grouped = Dictionary(grouping: tracks) { $0.parentIndexNumber ?? 1 }
            let discs = grouped.keys.sorted()
            ForEach(discs, id: \.self) { disc in
                Section {
                    trackRows(tracks.indices.filter { (tracks[$0].parentIndexNumber ?? 1) == disc })
                } header: {
                    if discs.count > 1 { Text("ディスク \(disc)") }
                }
            }
        }
    }

    private func trackRows(_ indices: [Int]) -> some View {
        ForEach(indices, id: \.self) { index in
            let track = tracks[index]
            Button {
                // 同じ曲が複数回入ったプレイリストでも、タップした位置から再生する。
                player.play(items: tracks, startingAt: index)
            } label: {
                AstraTrackRow(track: track, isPlaying: player.currentItem?.id == track.id)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .leading) {
                Button("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    player.playNext([track])
                }
                .tint(.accentColor)
            }
            .accessibilityAction(named: "次に再生") { player.playNext([track]) }
        }
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
            let result =
                album.type == .playlist
                ? try await client.fetchTracks(inPlaylist: album.id)
                : try await client.fetchTracks(inAlbum: album.id)
            try Task.checkCancellation()
            tracks = result.items
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

#Preview {
    NavigationStack {
        AstraAlbumDetailView(album: MediaItem(id: "preview-album", name: "夜の散歩", type: .musicAlbum))
    }
    .environment(AuthStore())
    .environment(PlaybackEngine())
}
