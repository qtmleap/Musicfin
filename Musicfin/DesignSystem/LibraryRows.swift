import SwiftUI

/// 曲一覧の 1 行。再生中の曲はアクセントカラーとインジケーターで示す。
struct TrackRow: View {
    let track: MediaItem
    /// アルバム内ではトラック番号を、横断的な一覧ではアートワークを出す。
    var showsArtwork = false
    var isPlaying = false

    var body: some View {
        HStack(spacing: 12) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayName)
                    .font(.body)
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                    .lineLimit(1)

                if showsArtwork, let artist = track.displayArtist {
                    Text(artist)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if track.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let duration = track.duration {
                Text(duration.timeLabel)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var leading: some View {
        if showsArtwork {
            ArtworkView(item: track, size: 44, cornerRadius: 6)
        } else if isPlaying {
            // 再生中は番号の代わりに音波アイコンを出す（Apple Music と同じ表現）。
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
        } else {
            Text(track.indexNumber.map(String.init) ?? "–")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28)
        }
    }
}

/// アルバム／プレイリストのカード。カルーセルとグリッドの両方で使う。
struct AlbumCard: View {
    let item: MediaItem
    var size: CGFloat = 160
    var showsSubtitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(item: item, size: size, cornerRadius: 10)

            Text(item.displayName)
                .font(.subheadline)
                .lineLimit(1)

            if showsSubtitle {
                Text(item.albumArtist ?? item.displayArtist ?? item.albumSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: size)
    }
}

/// アーティスト一覧の 1 行。アートワークは円形にする。
struct ArtistRow: View {
    let artist: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: artist, size: 52, cornerRadius: 26)
            Text(artist.displayName)
                .font(.body)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(.rect)
    }
}

/// 見出しと「すべて表示」を備えた横スクロールのセクション。
struct CarouselSection<Content: View>: View {
    let title: String
    var destination: (() -> AnyView)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title2.bold())
                Spacer()
                if let destination {
                    NavigationLink {
                        destination()
                    } label: {
                        Text("すべて表示").font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    content
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}
