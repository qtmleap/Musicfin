import SwiftUI

/// 作品そのものを主役にするため、影や色付きのカードを足さず文字の階層だけで補足する。
struct AstraAlbumCard: View {
    let item: MediaItem
    var size: CGFloat = 160
    var showsSubtitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(item: item, size: size, cornerRadius: 6)
                .accessibilityHidden(true)
            Text(item.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if showsSubtitle {
                Text(item.albumArtist ?? item.displayArtist ?? item.albumSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(width: size, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// 通常の一覧では文字を折り返し、寸法が決まっているホームの三段組だけを一行にする。
struct AstraTrackRow: View {
    let track: MediaItem
    var showsArtwork = false
    var isPlaying = false
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                ArtworkView(item: track, size: 44, cornerRadius: 4)
                    .accessibilityHidden(true)
            } else {
                Text(track.indexNumber.map(String.init) ?? "–")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayName)
                    .font(.body)
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                if showsArtwork, let artist = track.displayArtist {
                    Text(artist).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .lineLimit(compact ? 1 : nil)
            .fixedSize(horizontal: false, vertical: !compact)
            Spacer(minLength: 4)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("再生中の曲")
            }
            if let duration = track.duration {
                Text(duration.timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [track.displayName]
        if showsArtwork, let artist = track.displayArtist { parts.append(artist) }
        if let duration = track.duration { parts.append(duration.timeLabel) }
        if isPlaying { parts.append("再生中の曲") }
        return parts.joined(separator: "、")
    }
}

struct AstraArtistRow: View {
    let artist: MediaItem

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(item: artist, size: 52, cornerRadius: 26)
                .accessibilityHidden(true)
            Text(artist.displayName)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 56)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// 見出しと操作を分離し、文字拡大で横幅が足りなければ縦に並べる。
struct AstraCarouselSection<Content: View>: View {
    let title: String
    var destination: (() -> AnyView)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    heading
                    Spacer(minLength: 16)
                    moreLink
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    moreLink
                }
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) { content }
                    .padding(.horizontal, 16)
                    .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    private var heading: some View {
        Text(title)
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var moreLink: some View {
        if let destination {
            NavigationLink {
                destination()
            } label: {
                Text("すべて表示").font(.subheadline).frame(minHeight: 44)
            }
            .accessibilityLabel("\(title)、すべて表示")
        }
    }
}
