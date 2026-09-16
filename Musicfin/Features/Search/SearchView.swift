import SwiftUI
import UIKit

/// 入力前にも探し方を示し、検索結果とブラウズを同じ素朴なリストでつなぐ。
struct SearchView: View {
    /// 検索欄は iOS 26 の検索タブとしてタブバー側に出すので、入力そのものは `RootView` が持つ。
    @Binding var query: String

    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @Environment(AlbumCatalog.self) private var catalog
    /// 上端の罫線を 1 物理画素で描くため（仕様 9 章）。
    @Environment(\.displayScale) private var displayScale
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var retryGeneration = 0

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tracks: [MediaItem] { results.filter { $0.type == .audio } }
    private var horizontalMargin: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 34.5 : 20
    }

    var body: some View {
        Group {
            if term.isEmpty {
                browse
            } else {
                resultList
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackdrop())
        .tint(.pink)
        .navigationTitle("検索")
        // 入力前は大きな画面名をツールバー内に置く。標準の large はバーの下段に積まれ、
        // Apple 実機より 59 pt 低い位置から始まってしまう（仕様 1.1 章）。
        .toolbarTitleDisplayMode(term.isEmpty ? .inlineLarge : .automatic)
        .libraryNavigationMargins(horizontalMargin)
        .overlay { searchStatus }
        .onChange(of: query) { _, _ in
            // 古い語句の結果を新しい検索結果と誤認させないため、入力変更時に消す。
            results = []
            errorMessage = nil
            isSearching = !term.isEmpty
        }
        .task(id: [query, String(retryGeneration)]) { await search() }
    }

    private var resultList: some View {
        let separatorTrailingInset = horizontalMargin
        return List {
            // 一覧の上の罫線だけは左 20 pt から引き、**この 1 本だけ自分で描く**（仕様 9 章）。
            // システムの区切り線は太さを指定できず 1 pt（3 物理画素）で出るのに対し、
            // Apple 実機の上端の 1 本は 1 物理画素だったため。行どうしの罫線は 3 物理画素で
            // 一致しているので、そちらはシステムのまま触らない。
            // 届く範囲は `alignmentGuide` ではなく行の余白で作る。自分で描く矩形なので、
            // 左 20 pt・右 0 pt はそのまま `listRowInsets` で表せる。
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1 / displayScale)
                .listRowInsets(
                    EdgeInsets(top: 0, leading: horizontalMargin, bottom: 0, trailing: 0)
                )
                .listRowSeparator(.hidden)

            // 種別で分けず、サーバーが返した順のまま 1 つの一覧に混ぜる（仕様 9 章）。
            ForEach(results) { item in
                resultRow(item)
                    // 画像 56 pt に上下 10 pt で行ピッチ 76 pt。
                    .listRowInsets(
                        EdgeInsets(
                            top: 10,
                            leading: horizontalMargin,
                            bottom: 10,
                            trailing: horizontalMargin
                        )
                    )
                    .alignmentGuide(.listRowSeparatorLeading) { _ in
                        SearchResultRow.artworkSize + SearchResultRow.titleSpacing
                    }
                    // この画面だけ罫線を画面の右端まで伸ばす。仕様 1.1 章の 20 pt に対する例外で、
                    // 他の一覧へ広げてはいけない（仕様 9 章）。
                    .alignmentGuide(.listRowSeparatorTrailing) {
                        $0[.trailing] + separatorTrailingInset
                    }
            }
        }
        .listStyle(.plain)
    }

    /// 入力前の画面。Apple Music の分類タイルに倣い、ジャンルを大きなタイルで並べる。
    private var browse: some View {
        GeometryReader { geometry in
            let metrics = BrowseTileMetrics(width: geometry.size.width)
            ScrollView {
                LazyVGrid(columns: metrics.gridItems, spacing: 12) {
                    ForEach(Array(catalog.genres.enumerated()), id: \.element) { index, genre in
                        NavigationLink {
                            AlbumGridView(title: genre, albums: catalog.albums(in: genre))
                        } label: {
                            BrowseTile(title: genre, index: index, height: metrics.height)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // iPad は split detail 共通の 34.5 pt、iPhone は一覧本体の 20 pt に揃える（仕様 1.1・6 章）。
                .padding(.horizontal, horizontalMargin)
                // 上端はツールバーが返す間隔だけで足りる。ここで足すと見出しとタイルが離れる。
                .padding(.bottom, 16)
            }
            .overlay {
                if catalog.genres.isEmpty {
                    if catalog.isComplete {
                        ContentUnavailableView("ジャンルがありません", systemImage: "guitars")
                    } else if let message = catalog.errorMessage {
                        LoadErrorView(message: message) { await loadGenres() }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task { await loadGenres() }
    }

    private func loadGenres() async {
        guard let client = auth.client else { return }
        await catalog.loadAll { try await client.fetchAlbums(startIndex: $0) }
    }

    @ViewBuilder
    private func resultRow(_ item: MediaItem) -> some View {
        switch item.type {
        case .audio:
            // 曲の行だけ行末に「…」を置く。遷移する行は「›」が付く（仕様 9 章）。
            HStack(spacing: 0) {
                Button {
                    if let index = tracks.firstIndex(where: { $0.id == item.id }) {
                        player.play(items: tracks, startingAt: index)
                    }
                } label: {
                    SearchResultRow(item: item, subtitle: subtitle(for: item))
                }
                .buttonStyle(.plain)

                RowMenu {
                    Button {
                        player.playNext([item])
                    } label: {
                        Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button {
                        Task { await library.toggleFavorite(item) }
                    } label: {
                        Label(
                            item.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                            systemImage: item.isFavorite ? "heart.slash" : "heart"
                        )
                    }
                }
            }
        case .musicArtist:
            NavigationLink {
                ArtistDetailView(artist: item)
            } label: {
                SearchResultRow(item: item, subtitle: subtitle(for: item), isCircular: true)
            }
        default:
            NavigationLink {
                AlbumDetailView(album: item)
            } label: {
                SearchResultRow(item: item, subtitle: subtitle(for: item))
            }
        }
    }

    /// 副題は「種別を示す語 ＋ 中点 ＋ 補足」。区分見出しを出さないので、
    /// 種別がここでしか分からない（仕様 9 章）。補足は曲・アルバムのアーティストだけ。
    ///
    /// ここだけ明示キーを使う。日本語は同じ「曲」でも、ライブラリの分類名は集合を指すので
    /// 英語では "Songs"、ここは 1 件を指すので "Song" と、同じ語から 2 通りを引く必要がある。
    /// 既存のキーは分類名として複数形で埋まっているため、1 件を指す側に別のキーを与える。
    private func subtitle(for item: MediaItem) -> String {
        // 種別語はこの 4 種にだけ出す。`ItemKind` は他にもあり、`type` は省略もされうるので、
        // 当てはまらないものを「プレイリスト」に丸めると副題が嘘をつく。分からないときは黙る。
        let kind: String? =
            switch item.type {
            case .audio: String(localized: "search.type.song", defaultValue: "曲")
            case .musicAlbum: String(localized: "search.type.album", defaultValue: "アルバム")
            case .musicArtist: String(localized: "search.type.artist", defaultValue: "アーティスト")
            case .playlist: String(localized: "search.type.playlist", defaultValue: "プレイリスト")
            default: nil
            }
        guard let kind else { return "" }
        guard item.type == .audio || item.type == .musicAlbum,
            let artist = item.displayArtist ?? item.albumArtist
        else {
            return kind
        }
        return "\(kind) · \(artist)"
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

/// 検索結果の 1 行。種別で分けない 1 つの一覧に混ぜるので、骨格は全種別で共通にする（仕様 9 章）。
private struct SearchResultRow: View {
    /// 画像 56 pt、そこから本文まで 12 pt で、本文の左端が 88 pt になる。
    /// 罫線の左端も同じ基準で引くので、`alignmentGuide` の Sendable なクロージャから触れるようにする。
    nonisolated static let artworkSize: CGFloat = 56
    nonisolated static let titleSpacing: CGFloat = 12

    let item: MediaItem
    let subtitle: String
    /// アーティストだけは Apple 実機と同じく円で見せる（仕様 9 章）。
    var isCircular = false

    var body: some View {
        HStack(spacing: Self.titleSpacing) {
            // 角丸はこの画面だけ 4 pt。Apple の輪郭の実測から円弧で近似した値（精度は約 ±0.5 pt）で、
            // 他画面の 8 pt へ波及させない（仕様 9 章）。アーティストは直径 56 pt の円のまま。
            ArtworkView(
                item: item, size: Self.artworkSize,
                cornerRadius: isCircular ? Self.artworkSize / 2 : 4
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                // 種別も補足も無いときは行を作らない。空の 2 行目は題名を上へずらすだけで何も伝えない。
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        // 階層的な `.secondary` は地に対する不透明度なので、黒地で Apple より暗く沈む。
                        // ラベル色そのものを指定して、地が変わっても同じ色になるようにする（仕様 9 章）。
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .contentShape(.rect)
    }
}

#Preview {
    NavigationStack { SearchView(query: .constant("")) }
        .environment(AuthStore())
        .environment(PlaybackEngine())
        .environment(LibraryStore())
        .tint(.pink)
        .environment(AlbumCatalog())
}
