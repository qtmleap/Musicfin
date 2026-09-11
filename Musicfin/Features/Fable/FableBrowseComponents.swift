import SwiftUI

// Fable 版のブラウズ画面で共有する部品。ログイン・設定と同じ「ピンクの淡いグラデーション + ガラス」で揃える。

/// 各画面の背景。タブを跨いでも同じ世界観に見えるよう、ログイン・設定と同じグラデーションを敷く。
/// `List` に重ねるときは `.scrollContentBackground(.hidden)` を併用する。
struct FableBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color.pink.opacity(0.14), Color(.systemBackground), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

/// アルバム／プレイリストのカード。角を大きめに取り、淡い影で背景のグラデーションから浮かせる。
struct FableAlbumCard: View {
    let item: MediaItem
    var size: CGFloat = 160
    /// 省略時はアーティスト名。アーティスト詳細のように文脈で自明なときは別の文言（年など）に差し替える。
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(item: item, size: size, cornerRadius: 14)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle ?? item.albumArtist ?? item.displayArtist ?? item.albumSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: size)
    }
}

/// 曲一覧の 1 行。再生中の曲は tint（Fable ではピンク）で示す。
struct FableTrackRow: View {
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
                    .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
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
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
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
            ArtworkView(item: track, size: 44, cornerRadius: 8)
        } else if isPlaying {
            // 再生中は番号の代わりに音波アイコンを出す（Apple Music と同じ表現）。
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.tint)
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

/// アーティスト一覧の 1 行。円形のアートワークにピンクの細い縁を付けて、アルバムと見分けやすくする。
struct FableArtistRow: View {
    let artist: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: artist, size: 52, cornerRadius: 26)
                .overlay(Circle().strokeBorder(.pink.opacity(0.35), lineWidth: 1.5))
            Text(artist.displayName)
                .font(.body)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(.rect)
    }
}

/// アルバム／プレイリストなど「入れ物」の 1 行。
struct FableContainerRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(item: item, size: 52, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .lineLimit(1)
                Text(item.albumArtist ?? item.displayArtist ?? item.albumSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }
}

/// ライブラリのメニュー行に付けるアイコン。iPod のメニューのように種類ごとの色付きタイルで示す。
struct FableMenuIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(
                LinearGradient(colors: [.pink, .red], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: 9, style: .continuous)
            )
    }
}

/// 見出しと「すべて表示」を備えた横スクロールのセクション。
/// 「すべて表示」はテキストリンクではなくガラスのカプセルにして、押せることを分かりやすくする。
struct FableCarousel<Content: View, Destination: View>: View {
    let title: String
    @ViewBuilder var destination: Destination
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.title2.bold())
                Spacer()
                NavigationLink {
                    destination
                } label: {
                    Text("すべて表示")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
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

/// ホームとアルバム一覧で同じ列幅を使い、ウインドウのリサイズ時にも列を揃える。
/// 端末名ではなく利用可能幅で列数を決める（`docs/ui-spec.md` 6 章）。
struct FableGridMetrics {
    let columns: Int
    let size: CGFloat

    init(width: CGFloat) {
        let available = max(1, width - 32)
        if width < 360 {
            columns = 1
        } else if width < 600 {
            columns = 2
        } else {
            columns = max(3, Int((available + 12) / 192))
        }
        size = max(1, (available - CGFloat(columns - 1) * 12) / CGFloat(columns))
    }

    var gridItems: [GridItem] { Array(repeating: GridItem(.fixed(size), spacing: 12), count: columns) }
}

/// 読み込み失敗時の案内。ガラスのカードに載せて背景と区別する。
struct FableLoadError: View {
    let message: String
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(.pink)
            Text("読み込めませんでした").font(.headline)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("再試行") {
                isRetrying = true
                Task {
                    await retry()
                    isRetrying = false
                }
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.white)
            .disabled(isRetrying)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
    }
}
