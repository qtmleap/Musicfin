import SwiftUI
import UIKit

enum LibraryRoute: Hashable {
    case albums, artists, playlists, songs, favorites, genres
}

/// 一覧の並べ替え。Jellyfin へ再問い合わせせず、取得済みの一覧をその場で並べ替える。
enum LibrarySort: Hashable {
    case title, artist, year

    var label: String {
        switch self {
        case .title: String(localized: "タイトル")
        case .artist: String(localized: "アーティスト")
        case .year: String(localized: "リリース年")
        }
    }

    func sort(_ items: [MediaItem]) -> [MediaItem] {
        switch self {
        case .title:
            items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .artist:
            items.sorted {
                let left = $0.albumArtist ?? $0.displayArtist ?? ""
                let right = $1.albumArtist ?? $1.displayArtist ?? ""
                if left == right {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        case .year:
            // 年が無い項目を上へ出さないよう、未設定は最後にまとめる。
            items.sorted {
                let left = $0.productionYear ?? Int.min
                let right = $1.productionYear ?? Int.min
                if left == right {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return left > right
            }
        }
    }
}

/// 並べ替えメニュー。Apple Music と同じく右上に置き、現在の並びに印を付ける。
struct LibrarySortMenu: ToolbarContent {
    @Binding var order: LibrarySort
    let options: [LibrarySort]

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("並べ替え", selection: $order) {
                    ForEach(options, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
            } label: {
                // ツールバーの記号はアクセント色にしない（仕様 1.1 章）。
                // 階層スタイルの `.primary` は地の色（ここでは tint）を継いでしまうので、
                // ラベル色そのものを指す `Color.primary` を渡す。
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(Color.primary)
            }
            .accessibilityLabel("並べ替え")
        }
    }
}

extension [MediaItem] {
    /// 一覧内の絞り込み。作品名とアーティスト名のどちらでも引けるようにする。
    func matching(_ query: String) -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        return filter { item in
            let fields = [item.displayName, item.albumArtist ?? "", item.displayArtist ?? ""]
            return fields.contains { $0.localizedStandardContains(trimmed) }
        }
    }
}

/// ライブラリの入口。Apple Music と同じく種類のメニューを縦に並べ、その下に最近追加したアルバムを見せる。
struct LibraryView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @State private var showsAccount = false
    /// グリッドの遷移は `NavigationLink` ではなくここに入れる。`List` の行に `NavigationLink` を置くと、
    /// カードごとではなく行全体の入口とみなされて右端に「›」が描かれてしまう。
    @State private var selectedAlbum: MediaItem?

    private var accountName: String? {
        if case .signedIn(let user) = auth.state, !user.isEmpty { return user }
        return nil
    }

    private let menu: [(route: LibraryRoute, title: LocalizedStringResource, icon: String)] = [
        (.playlists, "プレイリスト", "music.note.list"),
        (.artists, "アーティスト", "music.mic"),
        (.albums, "アルバム", "square.stack"),
        (.songs, "曲", "music.note"),
        (.favorites, "お気に入りの曲", "star"),
        (.genres, "ジャンル", "guitars"),
    ]

    var body: some View {
        GeometryReader { geometry in
            List {
                HStack {
                    Text("ライブラリ").font(.largeTitle.bold())
                    Spacer()
                    Button {
                        showsAccount = true
                    } label: {
                        AccountAvatar(name: accountName, size: 44)
                    }
                    .accessibilityLabel("アカウント")
                    .accessibilityIdentifier("library.account")
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
                .listRowSeparator(.hidden)

                if let album = library.lastPlayedAlbum { lastPlayedCard(album) }

                ForEach(menu, id: \.route) { entry in
                    NavigationLink(value: entry.route) {
                        // アイコン 24 pt ＋ 間隔 17 pt で、文字の左端が Apple 実機と同じ 61 pt になる。
                        HStack(spacing: 17) {
                            MenuIcon(systemImage: entry.icon)
                            Text(entry.title).font(.body)
                        }
                        // 行の高さは Apple 実機の 52 pt に合わせる（縦余白は行側で 0 にする）。
                        .frame(minHeight: 52)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .accessibilityIdentifier("library.\(entry.route)")
                }

                if !library.recentlyAdded.isEmpty {
                    recentlyAdded(width: geometry.size.width)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await library.loadHome(force: true) }
        }
        .background(AppBackdrop())
        .toolbarVisibility(.hidden, for: .navigationBar)
        .sheet(isPresented: $showsAccount) { AccountView() }
        .navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .albums: AlbumGridView(title: String(localized: "アルバム"))
            case .artists: LibraryCollectionView(kind: .artists)
            case .playlists: LibraryCollectionView(kind: .playlists)
            case .songs: SongsView()
            case .favorites: FavoriteTracksView()
            case .genres: GenreListView()
            }
        }
        .navigationDestination(item: $selectedAlbum) { AlbumDetailView(album: $0) }
        .task { await library.loadHome() }
    }

    /// 見出しとカテゴリの間に、最後に再生したアルバムを 1 件だけ中央に置く（仕様 1.1 章）。
    /// 履歴が無いときは `library.lastPlayedAlbum` が nil になり、領域ごと出さない。
    private func lastPlayedCard(_ album: MediaItem) -> some View {
        Button {
            selectedAlbum = album
        } label: {
            VStack(spacing: 8) {
                ArtworkView(item: album, size: 110, cornerRadius: 8)
                // 画像と同じ幅に収め、はみ出す作品名は末尾を省略する。
                Text(album.displayName)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 110)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
        .listRowSeparator(.hidden)
    }

    /// メニューの下に最近追加を並べ、ライブラリ直下からもアルバムへ入れるようにする。
    private func recentlyAdded(width: CGFloat) -> some View {
        let metrics = AlbumGridMetrics(width: width)
        return Section {
            LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: AlbumGridMetrics.rowSpacing) {
                ForEach(library.recentlyAdded) { album in
                    Button {
                        selectedAlbum = album
                    } label: {
                        AlbumCard(item: album, size: metrics.size)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
        } header: {
            Text("最近追加した項目")
                .font(.title2.bold())
                // 見出しの地は secondary なので、階層スタイルではなくラベル色を直に指す。
                .foregroundStyle(Color.primary)
                .textCase(nil)
                // 上は 16 pt も空けると最後のカテゴリの罫線から見出しまでが Apple 実機より 13 pt 広がる。
                // 見出しの文字自体が持つ行間の余白があるので、行側は最小限にとどめる。
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 5, trailing: 20))
        }
    }
}

// MARK: - アルバム一覧

/// アルバムのグリッド。`albums` を渡せばその一覧を、渡さなければカタログ全体を無限スクロールで出す。
struct AlbumGridView: View {
    let title: String
    var albums: [MediaItem]?

    @Environment(AuthStore.self) private var auth
    @Environment(AlbumCatalog.self) private var catalog
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var query = ""
    @State private var order = LibrarySort.title
    /// 収録曲を集めている間は二重に押させない。アルバム数だけ問い合わせが走るので時間がかかる。
    @State private var isPreparing = false

    private var source: [MediaItem] { albums ?? catalog.items }
    private var items: [MediaItem] { order.sort(source.matching(query)) }

    var body: some View {
        GeometryReader { geometry in
            let metrics = AlbumGridMetrics(width: geometry.size.width)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !items.isEmpty {
                        TrackListActions(
                            play: { play(shuffled: false) },
                            shuffle: { play(shuffled: true) },
                            listInsets: nil
                        )
                        .disabled(isPreparing)
                        .padding(.horizontal, 20)
                        // 検索欄の下端から 25 pt、ボタン下端からグリッドまで 24 pt（Apple 実機の実測）。
                        // 検索欄と ScrollView の間に既に約 15 pt 入るので、足すのは差分の 10 pt だけ。
                        .padding(.top, 10)
                        .padding(.bottom, 24)
                    }

                    LazyVGrid(columns: metrics.gridItems, alignment: .leading, spacing: AlbumGridMetrics.rowSpacing) {
                        ForEach(items) { album in
                            NavigationLink {
                                AlbumDetailView(album: album)
                            } label: {
                                AlbumCard(item: album, size: metrics.size)
                            }
                            .buttonStyle(.plain)
                            // 撮影テストが位置ではなく識別子でアルバムを開けるようにする。
                            // 一覧の先頭は操作列の「再生」なので、順番で引くと詳細へ入れない。
                            .accessibilityIdentifier("album.card")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                    // 絞り込み中に次ページを読み続けると一覧が飛ぶので、全件表示のときだけ継ぎ足す。
                    if albums == nil, query.isEmpty {
                        if let message = catalog.errorMessage {
                            LoadErrorView(message: message) { await loadNext() }
                        } else if !catalog.isComplete {
                            ProgressView()
                                .padding()
                                .task(id: catalog.items.count) { await loadNext() }
                        }
                    }
                }
            }
            .overlay {
                if items.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if items.isEmpty, albums != nil || catalog.isComplete {
                    ContentUnavailableView("アルバムがありません", systemImage: "square.stack")
                }
            }
        }
        .background(AppBackdrop())
        .navigationTitle(title)
        // 一覧の画面名は左寄せの largeTitle（仕様 1.1 章）。中央インラインにはしない。
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
        .libraryNavigationMargins()
        .toolbar { LibrarySortMenu(order: $order, options: [.title, .artist, .year]) }
    }

    /// 一覧に出ているアルバムの全曲を対象にする（仕様 1.1 章）。
    private func play(shuffled: Bool) {
        let albums = items
        isPreparing = true
        Task {
            defer { isPreparing = false }
            let tracks = await library.tracks(forAll: albums)
            guard !tracks.isEmpty else { return }
            if player.isShuffled != shuffled { player.toggleShuffle() }
            player.play(items: tracks, startingAt: 0)
        }
    }

    private func loadNext() async {
        guard let client = auth.client else { return }
        await catalog.loadNext { try await client.fetchAlbums(startIndex: $0) }
    }
}

// MARK: - ジャンル

/// ジャンルは全アルバムを読み切ってから集約する（途中の分類を全件として見せない）。
struct GenreListView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(AlbumCatalog.self) private var catalog

    var body: some View {
        Group {
            if catalog.isComplete {
                if catalog.genres.isEmpty {
                    ContentUnavailableView("ジャンルがありません", systemImage: "guitars")
                } else {
                    List(catalog.genres, id: \.self) { genre in
                        NavigationLink {
                            AlbumGridView(title: genre, albums: catalog.albums(in: genre))
                        } label: {
                            HStack(spacing: 14) {
                                MenuIcon(systemImage: "guitars")
                                Text(genre)
                                Spacer()
                                Text("\(catalog.albums(in: genre).count)")
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // 行送りは変えずに左右だけ 20 pt へ寄せたいので、上下は既定と同じ 11 pt を保つ。
                        .listRowInsets(EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20))
                        // 先頭行の上には罫線を引かない（仕様 1.1 章）。
                        .listRowSeparator(genre == catalog.genres.first ? .hidden : .automatic, edges: .top)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            } else if let message = catalog.errorMessage {
                LoadErrorView(message: message) { await load() }
            } else {
                ProgressView("すべてのアルバムを確認中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppBackdrop())
        .navigationTitle("ジャンル")
        // 一覧の画面名は左寄せの largeTitle（仕様 1.1 章）。中央インラインにはしない。
        .navigationBarTitleDisplayMode(.large)
        .libraryNavigationMargins()
        .task { await load() }
    }

    private func load() async {
        guard let client = auth.client else { return }
        await catalog.loadAll { try await client.fetchAlbums(startIndex: $0) }
    }
}

// MARK: - アーティスト / プレイリスト

struct LibraryCollectionView: View {
    enum Kind { case artists, playlists }
    let kind: Kind

    @Environment(LibraryStore.self) private var library
    @State private var isLoading = true
    @State private var query = ""

    private var source: [MediaItem] { kind == .artists ? library.artists : library.playlists }
    private var items: [MediaItem] {
        source.matching(query)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    private var title: LocalizedStringResource { kind == .artists ? "アーティスト" : "プレイリスト" }
    private var horizontalMargin: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 34.5 : 20
    }
    /// 行の上下余白。画像の一辺（アーティスト 48 pt・プレイリスト 64 pt）に対応させる（仕様 1.1 章）。
    private var rowVerticalPadding: CGFloat { kind == .artists ? 4 : 8 }

    var body: some View {
        List(items) { item in
            NavigationLink {
                if kind == .artists {
                    ArtistDetailView(artist: item)
                } else {
                    AlbumDetailView(album: item)
                }
            } label: {
                if kind == .artists {
                    ArtistRow(artist: item)
                } else {
                    // プレイリストにアルバムの副題は出ないので、曲数を添えて中身を推し量れるようにする。
                    ContainerRow(item: item, subtitle: playlistSubtitle(item))
                }
            }
            // 撮影テストが詳細へ進む入口。一覧から消えたことも到達の判定に使う。
            .accessibilityIdentifier(kind == .artists ? "artist.row" : "playlist.row")
            // 上下の余白は画像の一辺で決まる。アーティストは 48 pt 画像で 4 pt（送り 56 pt）、
            // プレイリストは 64 pt 画像で 8 pt（送り 80 pt）。同じ `List` を通るからといって
            // 一律にすると、画像が大きい側だけ詰まって見える（仕様 1.1 章の表）。
            .listRowInsets(
                EdgeInsets(
                    top: rowVerticalPadding,
                    leading: horizontalMargin,
                    bottom: rowVerticalPadding,
                    trailing: horizontalMargin
                )
            )
            // 罫線の右端は `List` の既定 16 pt のまま。**行の中身の 20 pt とは揃わないのが Apple の実測**で、
            // ここを 20 pt へ寄せる `alignmentGuide` を足すと、一致していたこの画面群が逆にずれる。
            // 右端が画面ごとに違う（一覧 16 pt・詳細 20 pt・検索 0 pt）ことは仕様 1.1 章の表にある（仕様 1.1 章）。
            // 先頭行の上には罫線を引かない。Apple 実機は 1 行目と 2 行目の間から始まる（仕様 1.1 章）。
            .listRowSeparator(item.id == items.first?.id ? .hidden : .automatic, edges: .top)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppBackdrop())
        .navigationTitle(title)
        // 一覧の画面名は左寄せの largeTitle（仕様 1.1 章）。中央インラインにはしない。
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
        .libraryNavigationMargins(horizontalMargin)
        .toolbar {
            if kind == .artists {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Label("タイトル順", systemImage: "checkmark")
                    } label: {
                        // ツールバーの記号は白の primary（仕様 1.1 章）。tint を継がせない。
                        Image(systemName: "line.3.horizontal.decrease")
                            .foregroundStyle(Color.primary)
                    }
                    .accessibilityLabel("並べ替え")
                }
            }
        }
        .overlay {
            if isLoading, source.isEmpty {
                ProgressView()
            } else if items.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if source.isEmpty {
                ContentUnavailableView(
                    kind == .artists ? "アーティストがありません" : "プレイリストがありません",
                    systemImage: kind == .artists ? "music.mic" : "music.note.list"
                )
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func playlistSubtitle(_ item: MediaItem) -> String? {
        guard kind == .playlists, let count = item.childCount else { return nil }
        return String(localized: "\(count) 曲")
    }

    private func load() async {
        isLoading = true
        if kind == .artists { await library.loadArtists() } else { await library.loadPlaylists() }
        isLoading = false
    }
}

// MARK: - 曲

struct SongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var query = ""

    /// 区分の頭文字は作品名から採るので、並びの基準も作品名に合わせる（仕様 1.1 章）。
    /// サーバーの SortName 順のままだと B → T → C のように区分が前後して見える。
    private var tracks: [MediaItem] { LibrarySort.title.sort(library.tracks.matching(query)) }
    private var horizontalMargin: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 34.5 : 20
    }

    /// 並べ替えの基準（曲一覧はタイトル順）どおりに頭文字でまとめる。
    /// 並びは `tracks` で既に整っているので、ここでは出現順にまとめるだけでよい。
    private var sections: [(key: String, tracks: [MediaItem])] {
        var order: [String] = []
        var buckets: [String: [MediaItem]] = [:]
        for track in tracks {
            let key = Self.sectionKey(for: track.displayName)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(track)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// 数字と記号は Apple Music と同じく «#» にまとめる。読み仮名が無いので、
    /// 英字以外の文字はその文字自体を見出しにする。
    private static func sectionKey(for name: String) -> String {
        guard let first = name.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    var body: some View {
        ScrollViewReader { proxy in
            list
                .overlay(alignment: .trailing) {
                    if sections.count > 1 { sectionIndex(proxy: proxy) }
                }
        }
        .background(AppBackdrop())
        .navigationTitle("曲")
        // 一覧の画面名は左寄せの largeTitle（仕様 1.1 章）。中央インラインにはしない。
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
        .libraryNavigationMargins(horizontalMargin)
        .overlay { status }
        .task { await library.loadTracks() }
    }

    private var list: some View {
        List {
            if !library.tracks.isEmpty {
                TrackListActions(
                    play: { player.play(items: tracks, startingAt: 0) },
                    shuffle: {
                        if !player.isShuffled { player.toggleShuffle() }
                        player.play(items: tracks, startingAt: 0)
                    },
                    listInsets: horizontalMargin
                )
                .disabled(tracks.isEmpty)
            }

            ForEach(sections, id: \.key) { section in
                Section {
                    ForEach(section.tracks) { track in
                        SongListRow(track: track, queue: tracks, horizontalMargin: horizontalMargin)
                            .task {
                                if query.isEmpty { await library.loadMoreTracksIfNeeded(currentItem: track) }
                            }
                    }
                } header: {
                    Text(section.key)
                        .font(.system(size: 17, weight: .bold))
                        // 見出しの地は secondary なので、階層スタイルではなくラベル色を直に指す。
                        .foregroundStyle(Color.primary)
                        .textCase(nil)
                        .id(section.key)
                        // 下を 6 pt にしてあるのは、カプセル下端から先頭の画像までの合計 60.67 pt が
                        // Apple と一致したあとも、内訳が「見出しの字まで 36.67 / 字から画像まで 12.33」と
                        // Apple の 34.67 / 14.33 から 2 pt ずれていたため。足りないのは見出しの下だった（仕様 1.1 章）。
                        .listRowInsets(
                            EdgeInsets(
                                top: 8,
                                leading: horizontalMargin,
                                bottom: 6,
                                trailing: horizontalMargin
                            )
                        )
                }
            }

            if query.isEmpty, library.tracksState == .loading, !library.tracks.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        // 「再生 / シャッフル」から最初の頭文字見出しまでが 12 pt 広かった原因は
        // `listRowInsets` ではなく、`List` が節の前に足す既定の間隔（実測 22 pt）だった。
        // 見出し側の上余白 8 pt を削っても足りず、削れば見出しの字が行に貼り付く。
        // カプセル側（`TrackListActions`）はアルバム一覧と共用で、そちらは Apple と一致しているので触れない。
        // 10 pt は目標 34.3 pt から、カプセル下 12 pt・見出し上 8 pt・17 pt 太字の行内の余白約 4.3 pt を引いた残り（仕様 1.1 章）。
        // カプセル下端から先頭の画像の上端までの合計 60.67 pt は、この 10 pt と見出し下 6 pt で作る。
        // 一度この値を 12 pt にして合計を合わせたが、内訳を測ると見出しが 2 pt 下にいたので、
        // 足す場所を見出しの下へ移して 10 pt へ戻した。
        // 行送り・画像・罫線・左端は Apple と一致しているので触っていない。
        // この値は頭文字の区分どうしの間隔でもあるが、Apple 側の撮影に区分が 1 つしか写っておらず、
        // そちらが合っているかは**比較できていない**。
        .listSectionSpacing(10)
        .scrollContentBackground(.hidden)
        .refreshable { await library.loadTracks(force: true) }
    }

    /// 右端の頭文字索引。幅 16 pt を右端に寄せると文字の中心が Apple 実機と同じ約 385 pt に来る。
    private func sectionIndex(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            ForEach(sections, id: \.key) { section in
                Button {
                    proxy.scrollTo(section.key, anchor: .top)
                } label: {
                    Text(section.key)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 16)
    }

    @ViewBuilder
    private var status: some View {
        if !library.tracks.isEmpty, tracks.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if library.tracks.isEmpty {
            switch library.tracksState {
            case .idle, .loading: ProgressView()
            case .failed(let message): LoadErrorView(message: message) { await library.loadTracks() }
            case .loaded: ContentUnavailableView("曲がありません", systemImage: "music.note")
            }
        }
    }
}

private struct SongListRow: View {
    let track: MediaItem
    let queue: [MediaItem]
    let horizontalMargin: CGFloat

    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if let index = queue.firstIndex(where: { $0.id == track.id }) {
                    player.play(items: queue, startingAt: index)
                }
            } label: {
                TrackRow(
                    track: track, showsArtwork: true, artworkSize: 48,
                    isCurrent: player.currentItem?.id == track.id
                )
            }
            .buttonStyle(.plain)

            RowMenu {
                Button {
                    player.playNext([track])
                } label: {
                    Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    Task { await library.toggleFavorite(track) }
                } label: {
                    Label(
                        track.isFavorite ? "お気に入りから削除" : "お気に入りに追加",
                        systemImage: track.isFavorite ? "heart.slash" : "heart"
                    )
                }
            }
        }
        // 画像 48 pt に上下 4 pt で行送り 56 pt。画像どうしの間隔が Apple 実機の 8 pt になる。
        .listRowInsets(
            EdgeInsets(
                top: 4,
                leading: horizontalMargin,
                bottom: 4,
                trailing: horizontalMargin
            )
        )
    }
}

// MARK: - お気に入りの曲

struct FavoriteTracksView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var query = ""

    private var source: [MediaItem] { library.favoriteTracks.filter(\.isFavorite) }
    private var tracks: [MediaItem] { source.matching(query) }

    var body: some View {
        List {
            if !source.isEmpty {
                TrackListActions(
                    play: { player.play(items: tracks, startingAt: 0) },
                    shuffle: {
                        if !player.isShuffled { player.toggleShuffle() }
                        player.play(items: tracks, startingAt: 0)
                    }
                )
                .disabled(tracks.isEmpty)
            }

            ForEach(tracks) { track in
                HStack(spacing: 0) {
                    Button {
                        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
                            player.play(items: tracks, startingAt: index)
                        }
                    } label: {
                        TrackRow(
                            track: track, showsArtwork: true, artworkSize: 48,
                            isCurrent: player.currentItem?.id == track.id
                        )
                    }
                    .buttonStyle(.plain)

                    RowMenu {
                        Button {
                            player.playNext([track])
                        } label: {
                            Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button(role: .destructive) {
                            Task { await library.toggleFavorite(track) }
                        } label: {
                            Label("お気に入りから削除", systemImage: "heart.slash")
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .swipeActions {
                    Button {
                        Task { await library.toggleFavorite(track) }
                    } label: {
                        Label("お気に入りから削除", systemImage: "heart.slash")
                    }
                    .tint(.pink)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppBackdrop())
        .navigationTitle("お気に入りの曲")
        // 一覧の画面名は左寄せの largeTitle（仕様 1.1 章）。中央インラインにはしない。
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "検索")
        .libraryNavigationMargins()
        .overlay {
            if !source.isEmpty, tracks.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if tracks.isEmpty {
                switch library.homeState {
                case .idle, .loading: ProgressView()
                case .failed(let message):
                    LoadErrorView(message: message) { await library.loadHome(force: true) }
                case .loaded: ContentUnavailableView("お気に入りの曲がありません", systemImage: "heart")
                }
            }
        }
        .task { await library.loadHome() }
        .refreshable { await library.loadHome(force: true) }
    }
}

#Preview {
    NavigationStack {
        LibraryView()
    }
    .environment(AuthStore())
    .environment(LibraryStore())
    .environment(PlaybackEngine())
    .environment(AlbumCatalog())
}
