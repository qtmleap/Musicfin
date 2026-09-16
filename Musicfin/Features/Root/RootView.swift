import SwiftUI
import UIKit

/// アプリのルート。3 タブ + ミニプレイヤー + フルプレイヤー sheet（`docs/ui-spec.md` 1・3・4・6 章）。
struct RootView: View {
    private enum RootTab: Hashable { case home, new, radio, library, search }
    /// iPad の外枠寸法。基準画像 `docs/app/iPad/home.webp`（2732 × 2048 px、2 倍）の実測を pt に直した値。
    /// 板の左端 20 px・上端 65 px・下端 2017 px、角の半径 48 px、幅 539 px がそれぞれここに対応する。
    private enum PadShell {
        static let sidebarWidth: CGFloat = 269.5
        static let sidebarLeading: CGFloat = 10
        static let sidebarTop: CGFloat = 32
        static let sidebarBottom: CGFloat = 10
        static let sidebarCornerRadius: CGFloat = 24
        /// detail の左端は板の右端に接する。参照の黒い隙間 34.5 pt は detail 本文が持つ左右余白そのもの。
        static let detailOrigin: CGFloat = sidebarLeading + sidebarWidth
        /// sidebar の行の高さ。参照の選択背景 473 × 88 px（236.5 × 44 pt）に合わせる。
        /// `List` 既定のままだと 52 pt になり、行を下るほど参照との差が積み上がる。
        static let sidebarRowHeight: CGFloat = 44
        /// 行の左右余白。選択背景の幅 236.5 pt が (269.5 − 16.5 × 2) に一致する。
        static let sidebarRowInset: CGFloat = 16.5
        /// 作品画像を出す行の高さ。参照は記号だけの行より高く、行送りの実測から 51 pt になる。
        static let sidebarArtworkRowHeight: CGFloat = 51
        /// 一覧の上余白。参照の検索行の中心 234 px（117 pt）に合わせた実測値。
        static let sidebarListTopMargin: CGFloat = 21
        /// 板の中だけで使う accent。基準画像の記号の純色は実測 RGB(230, 67, 78) で、
        /// 他の画面が使う `Color.pink` より暗く赤寄り。板の外の tint はこれに合わせない。
        static let sidebarAccent = Color(red: 230 / 255, green: 67 / 255, blue: 78 / 255)
        /// 「お気に入りの曲」の枠の地。基準は記号ではなく作品画像と同じ大きさの淡い角丸タイルで、
        /// 地の実測は RGB(236, 239, 240)。暗い地に置くので明暗どちらでもこの色のままにする。
        static let sidebarTileFill = Color(red: 236 / 255, green: 239 / 255, blue: 240 / 255)
        /// account 行の高さ。44 pt のアバターと上下 12 pt から決まる。名前の長さでは動かさない。
        static let sidebarFooterHeight: CGFloat = 68
        /// account 行の中心を板の下端から測った位置。基準の中心 1931 px（965.5 pt）は板の下端
        /// 1013.5 pt の 48 pt 上にあたる。アバターや名前の中身が変わってもここは動かさない。
        static let sidebarFooterCenterInset: CGFloat = 48
        /// 行を持ち上げるぶんの余白。地はこれを含めて敷き、一覧の下端余白も合計に合わせる。
        static let sidebarFooterBottomPadding: CGFloat =
            sidebarFooterCenterInset - sidebarFooterHeight / 2
    }
    private enum PadDestination: Hashable {
        case home, search, new, radio
        case recentlyAdded, albums, artists, songs, playlists, favorites
        case playlist(MediaItem)
        /// 「ピン」の入れ子に並ぶ行。同じ作品が他の区分にも出るので、識別子を別にして撮影で取り違えない。
        case pinned(MediaItem)
        /// 画面をまだ持たない項目。参照の sidebar は行を選べるので、選択状態だけ保って本文に未対応を出す。
        case unavailable(PadUnavailable)

        /// 撮影テストが引く識別子。連想値をそのまま文字列にすると型名まで混ざるので、行ごとに短い名前を与える。
        var identifier: String {
            switch self {
            case .home: "home"
            case .search: "search"
            case .new: "new"
            case .radio: "radio"
            case .recentlyAdded: "recentlyAdded"
            case .albums: "albums"
            case .artists: "artists"
            case .songs: "songs"
            case .playlists: "playlists"
            case .favorites: "favorites"
            case .playlist(let playlist): "playlist.\(playlist.id)"
            case .pinned(let item): "pin.\(item.id)"
            case .unavailable(let screen): screen.rawValue
            }
        }
    }

    /// 参照の sidebar には在るが Jellyfin に対応する概念が無い項目。行の見た目と選択だけ再現する。
    private enum PadUnavailable: String, Hashable {
        case pins, downloaded, purchased, newPlaylist

        var title: LocalizedStringKey {
            switch self {
            case .pins: "ピン"
            case .downloaded: "ダウンロード済み"
            case .purchased: "購入した音楽"
            case .newPlaylist: "新規プレイリスト"
            }
        }

        var systemImage: String {
            switch self {
            case .pins: "pin"
            case .downloaded: "arrow.down.circle"
            case .purchased: "music.note.list"
            case .newPlaylist: "plus"
            }
        }
    }

    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var catalog = AlbumCatalog()
    @State private var selection: RootTab = .home
    @State private var padSelection: PadDestination = .home
    /// sidebar の区分は参照どおり開閉できる。初期は両方とも開いた状態を正とする。
    @State private var showsLibrarySection = true
    @State private var showsPlaylistSection = true
    /// 「ピン」も参照では入れ子が開いた状態で、中の作品が見えている。
    @State private var showsPinsSection = true
    @State private var showsAccount = false
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchQuery = ""
    // 比較撮影だけはネットワーク再生の成否に依存させず、参照の「Not Playing」を直接開く。
    // UI test の子プロセスへ明示したときだけ真になるため、通常起動の提示経路には入らない。
    @State private var showsPlayer = ProcessInfo.processInfo.environment["MUSICFIN_CAPTURE_PLAYER"] == "1"
    /// シーク中だけ iPad の sheet の対話的な終了を止める（仕様 4.1 章）。状態は `NowPlayingView` が更新する。
    /// iPhone 側はこの値では止めない。カスタム提示の終了 pan がシーク認識器の失敗を待つ形に替えた
    /// ので、成立後に `isEnabled` を切り替える必要が無くなった（仕様 4.1.1 章）。
    @State private var isScrubbing = false
    /// 一度でも再生が始まったか。`currentItem` は「キューに追加」「次に再生」で積んだだけでも
    /// 埋まるので、これを併せないとミニプレイヤーが再生前から出る（仕様 3 章）。
    /// 本来は再生側が持つべき状態だが、`Musicfin/Player/` は指示なしに変えない決まりなので、
    /// 表示側で覚える暫定である。
    @State private var hasStartedPlayback = false
    /// ミニプレイヤーの矩形（窓座標）を入れる箱。「ミニプレイヤーから展開」方式の出発・帰着に渡す（仕様 4.1.1 章）。
    /// **矩形を `@State` の値として持たない**のが要点で、持つと幾何の報告がこの画面全体の再評価を呼び、
    /// `tabViewBottomAccessory` の作り直し → 再計測、と輪になる。箱の作り直しを防ぐために `@State` で 1 度だけ作る。
    @State private var miniPlayerSource = PlayerSourceBox()
    /// フルプレイヤーの開き方。**実機比較のための一時的な切り替え**で、設定画面と同じキーを読む。
    @AppStorage(PlayerPresentationStyle.storageKey) private var playerStyle = PlayerPresentationStyle.slideUp

    var body: some View {
        Group {
            if isPhonePlayer {
                phoneTabs
            } else {
                padSplitView
            }
        }
        // ログイン・設定と同じピンクを操作色にして、リンク・選択状態・再生中表示まで統一する。
        .tint(.pink)
        .environment(catalog)
        // iPad は参照どおり sidebar を含む全窓を覆う。fitted sheet へ戻すと左右の構成が残ってしまう。
        .fullScreenCover(isPresented: padPlayerPresented) { playerContent }
        .playerPresentation(
            isPresented: customPlayerPresented,
            source: miniPlayerSource,
            style: playerStyle
        ) { customPlayerContent }
        // `initial: true` が要る。この画面が作り直されたときに既に再生中だと、値が真のまま変化せず
        // 通知が来ないので、再生中なのにミニプレイヤーが出ないまま取り残される。
        .onChange(of: player.isPlaying, initial: true) { _, isPlaying in
            if isPlaying { hasStartedPlayback = true }
        }
        // 待ち行列が空になったら忘れる（仕様 3 章）。次に積んだだけの曲でまた出てしまわないように。
        .onChange(of: player.queue.isEmpty) { _, isEmpty in
            if isEmpty { hasStartedPlayback = false }
        }
        // 帯が消えたら矩形を捨てる。報告してくるのは `MiniPlayerView` 自身なので、
        // 消えたあとは古い矩形が残り、**居ない帯から広がって見える**（仕様 4.1.1 章）。
        .onChange(of: showsMiniPlayer) { _, shows in
            if !shows {
                miniPlayerSource.rect = nil
                miniPlayerSource.view = nil
            }
        }
        .onChange(of: player.currentItem?.id) { _, id in
            if id == nil { showsPlayer = false }
        }
    }

    private var phoneTabs: some View {
        TabView(selection: $selection) {
            Tab("ホーム", systemImage: "house", value: .home) {
                homeNavigation
            }
            Tab("新着", systemImage: "square.grid.2x2", value: .new) {
                NavigationStack { AlbumGridView(title: String(localized: "新着"), albums: library.recentlyAdded) }
            }
            Tab("ラジオ", systemImage: "dot.radiowaves.left.and.right", value: .radio) {
                NavigationStack { RadioView() }
            }
            Tab("ライブラリ", systemImage: "square.stack", value: .library) {
                libraryNavigation
            }
            Tab("検索", systemImage: "magnifyingglass", value: .search, role: .search) {
                searchNavigation
            }
        }
        // 検索タブの入力欄はタブバーの位置に出し、画面名とタイルを押し下げない（仕様 1 章）。
        .searchable(text: $searchQuery, prompt: "アーティスト、曲、歌詞など")
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if showsMiniPlayer {
                MiniPlayerView(onFrameChange: { miniPlayerSource.rect = $0 }) { showsPlayer = true }
                    .background { PlayerZoomSource(source: miniPlayerSource) }
            }
        }
    }

    /// 参照の iPad は黒い窓の上に sidebar の板が浮き、detail はその板の下へ潜らない。
    /// `NavigationSplitView` は横向きでも左カラムを detail に重ねて出し、端の払いや toolbar の
    /// 切り替えで閉じてしまうので、板と detail を自分で並べる。閉じる導線はそもそも作らない。
    private var padSplitView: some View {
        ZStack(alignment: .topLeading) {
            // 窓の地は黒一色。detail は板ではなくこの地に続き、境目の線も置かない。
            Color.black
                .ignoresSafeArea()
            padDetailColumn
                .padding(.leading, PadShell.detailOrigin)
            padSidebar
                .frame(width: PadShell.sidebarWidth)
                .background {
                    let shape = RoundedRectangle(
                        cornerRadius: PadShell.sidebarCornerRadius, style: .continuous)
                    shape.fill(.ultraThinMaterial)
                    // 素の material は黒地の上で白 12 % まで明るくなる。参照の板は実測 6 % なので、
                    // 透け方は残したまま黒を重ねて明るさだけ合わせる。
                    shape.fill(Color.black.opacity(0.5))
                }
                .clipShape(
                    .rect(cornerRadius: PadShell.sidebarCornerRadius, style: .continuous)
                )
                .padding(.leading, PadShell.sidebarLeading)
                .padding(.top, PadShell.sidebarTop)
                .padding(.bottom, PadShell.sidebarBottom)
                // 板の位置は窓の端から測る。safe area を挟むと状態表示ぶんだけ下へずれる。
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showsAccount) { AccountView() }
    }

    private var padSidebar: some View {
        // 参照の板は bar を持たず、「編集」が板の左上に直に載る。`NavigationStack` を噛ませると
        // 窓の safe area ぶんだけ下がり、板の中で位置が合わなくなるので、見出しは自分で並べる。
        VStack(spacing: 0) {
            HStack {
                Button("編集") {}
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 6)

            List {
                padSidebarRow("検索", systemImage: "magnifyingglass", destination: .search)
                padSidebarRow("ホーム", systemImage: "house", destination: .home, accentsIcon: true)
                padSidebarRow("新着", systemImage: "square.grid.2x2", destination: .new)
                padSidebarRow(
                    "ラジオ", systemImage: "dot.radiowaves.left.and.right", destination: .radio,
                    accentsIcon: true)
                Section("ライブラリ", isExpanded: $showsLibrarySection) {
                    padPinsSidebarRow
                    padSidebarRow(
                        "最近追加した項目", systemImage: "clock", destination: .recentlyAdded,
                        accentsIcon: true)
                    padSidebarRow(
                        "アーティスト", systemImage: "music.mic", destination: .artists,
                        accentsIcon: true)
                    padSidebarRow(
                        "アルバム", systemImage: "square.stack", destination: .albums,
                        accentsIcon: true)
                    padSidebarRow("曲", systemImage: "music.note", destination: .songs, accentsIcon: true)
                    padSidebarRow(unavailable: .downloaded)
                }
                Section("プレイリスト", isExpanded: $showsPlaylistSection) {
                    padSidebarRow(
                        "すべてのプレイリスト", systemImage: "square.grid.3x3",
                        destination: .playlists, accentsIcon: true)
                    padFavoriteSongsSidebarRow
                    padSidebarRow(unavailable: .purchased)
                    ForEach(library.playlists) { playlist in
                        padPlaylistSidebarRow(playlist)
                    }
                    padSidebarRow(unavailable: .newPlaylist)
                }
            }
            // split view の外では一覧形式が既定に戻り、区分の開閉も行の余白も参照と食い違うので明示する。
            .listStyle(.sidebar)
            // 一覧側の下限を下げないと、行に高さを与えても sidebar 既定の 52 pt まで戻される。
            .environment(\.defaultMinListRowHeight, PadShell.sidebarRowHeight)
            // 区分の前の余白も既定のままだと参照より広い。見出しの位置を実測に合わせる。
            .listSectionSpacing(.custom(12))
            // 板の material を見せるため、一覧が持つ地は外す。
            .scrollContentBackground(.hidden)
            // 一覧の既定の上余白ぶんだけ「編集」から離れるので、板の中では自分で詰める。
            .contentMargins(.top, PadShell.sidebarListTopMargin, for: .scrollContent)
            // 基準の account 行は地を持たず、一覧の末尾がぼかし越しに透ける。`safeAreaInset` は
            // 場所を空けるだけで端の効果はそこまで伸びないので、帯として渡して効果の対象にする。
            // 末尾の行が隠れない余白もこれで確保されるため、`contentMargins` は足さない。
            .safeAreaBar(edge: .bottom, spacing: 0) { padSidebarFooter }
            // 端の効果は既定（hard）だと地を敷いたように見える。参照のぼかしは soft のほう。
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .task { await library.loadPlaylists() }
        }
    }

    private var padDetailColumn: some View {
        ZStack(alignment: .bottom) {
            padDetail
            if showsMiniPlayer {
                MiniPlayerView(
                    onFrameChange: { miniPlayerSource.rect = $0 },
                    forceExpanded: true
                ) { showsPlayer = true }
                .frame(maxWidth: 689)
                .frame(height: 63.5)
                .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 16)
                .background { PlayerZoomSource(source: miniPlayerSource) }
                // 下端 25 pt は窓の下端から測る（仕様 6 章）。帯は高さが決まっているので
                // `ignoresSafeArea` だけでは動かない。伸び縮みする枠でいったん包み、その枠を
                // 窓の下端まで広げてから 25 pt 詰める。枠のままだとホームインジケータぶん浮く。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 25)
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    /// `accentsIcon` は基準画像で記号だけ pink に塗られている行。文字は選ばれるまで白のままなので、
    /// 行ごと色を変えずに記号だけ塗り分ける。検索・新着・ピン・ダウンロード済みは基準でも白い。
    private func padSidebarRow(
        _ title: LocalizedStringKey, systemImage: String, destination: PadDestination,
        accentsIcon: Bool = false
    ) -> some View {
        padSidebarRow(destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(
                        accentsIcon || padSelection == destination
                            ? PadShell.sidebarAccent : Color.primary)
            }
        }
    }

    /// 未対応の項目も参照と同じ「選べる行」にする。静的な文字にすると選択の枠が出ず、
    /// 行の高さと文字色も他と揃わないため、見た目まで別物になってしまう。
    private func padSidebarRow(unavailable screen: PadUnavailable) -> some View {
        padSidebarRow(.unavailable(screen)) {
            Label(screen.title, systemImage: screen.systemImage)
        }
    }

    /// 参照の「ピン」は単独の行ではなく開閉する入れ子で、中に作品画像付きの行が並ぶ。
    /// Jellyfin に固定の概念は無いので、中身はライブラリ先頭のプレイリストを借りて並びだけ再現し、
    /// 本文は他の未対応項目と同じ案内に送る。
    private var padPinsSidebarRow: some View {
        DisclosureGroup(isExpanded: $showsPinsSection) {
            ForEach(pinnedItems) { item in
                padSidebarRow(.pinned(item), usesFixedHeight: false) {
                    HStack(spacing: 12) {
                        ArtworkView(item: item, size: 28, cornerRadius: 5)
                        Text(item.displayName)
                            .lineLimit(1)
                    }
                }
            }
        } label: {
            Label(PadUnavailable.pins.title, systemImage: PadUnavailable.pins.systemImage)
                // 選択されない見出しなので、他の未選択行と同じ色にする。
                // 指定しないと DisclosureGroup の label だけ tint の pink を拾い、参照の白と食い違う。
                .foregroundStyle(Color.primary)
                .accessibilityIdentifier("sidebar.pins")
                .frame(minHeight: PadShell.sidebarRowHeight)
        }
        .listRowInsets(
            EdgeInsets(
                top: 0, leading: PadShell.sidebarRowInset, bottom: 0,
                trailing: PadShell.sidebarRowInset)
        )
        // 参照の「ピン」は選ばれていない見出しなので地を持たない。指定しないと `DisclosureGroup` が
        // 既定の矩形を敷き、参照に無い面が出る。
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// 参照の「お気に入りの曲」だけは記号ではなく、作品画像と同じ 28 pt の淡い角丸タイルに
    /// accent の星を載せた枠で出る。記号に置き換えると前後のプレイリスト行と大きさが揃わない。
    private var padFavoriteSongsSidebarRow: some View {
        padSidebarRow(.favorites, usesFixedHeight: false) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(PadShell.sidebarTileFill)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "star.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(PadShell.sidebarAccent)
                    }
                Text("お気に入りの曲")
                    .lineLimit(1)
            }
        }
    }

    /// 参照と同じく 1 件だけ固定する。件数まで合わせないと入れ子の高さが変わり、以降の行がすべてずれる。
    private var pinnedItems: [MediaItem] { Array(library.playlists.prefix(1)) }

    /// プレイリストの行だけは参照どおり作品画像を出す。記号に置き換えるとどの一覧か見分けられない。
    private func padPlaylistSidebarRow(_ playlist: MediaItem) -> some View {
        padSidebarRow(.playlist(playlist), usesFixedHeight: false) {
            HStack(spacing: 12) {
                ArtworkView(item: playlist, size: 28, cornerRadius: 5)
                Text(playlist.displayName)
                    .lineLimit(1)
            }
        }
    }

    /// `usesFixedHeight` は記号と文字だけの行。参照の 44 pt に揃えるため高さを固定する。
    /// 作品画像を出す行は参照でも少し高いので、固定せず中身に任せる。
    private func padSidebarRow<Label: View>(
        _ destination: PadDestination, usesFixedHeight: Bool = true,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            // detail に残った深い path を破棄してから切り替え、常に選択先の root を表示する。
            homePath = NavigationPath()
            libraryPath = NavigationPath()
            searchPath = NavigationPath()
            if destination == .search { searchQuery = "" }
            padSelection = destination
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(
                    height: usesFixedHeight
                        ? PadShell.sidebarRowHeight : PadShell.sidebarArtworkRowHeight
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // 行の高さは自分で決める。既定の上下余白を残すと 52 pt になり、参照の 44 pt に収まらない。
        .listRowInsets(
            EdgeInsets(
                top: 0, leading: PadShell.sidebarRowInset, bottom: 0,
                trailing: PadShell.sidebarRowInset)
        )
        // 参照の板に行の区切り線は無い。一覧側へまとめて指定しても行までは届かない。
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("sidebar.\(destination.identifier)")
        .foregroundStyle(padSelection == destination ? PadShell.sidebarAccent : Color.primary)
        // 参照の選択背景は左右に余白を置いた 473×88 px（236.5×44 pt）で、角の半径は高さの半分に一致した。
        // 矩形のまま塗ると選択行だけ角が立つので、行の高さに追従する Capsule で塗る。
        // 左右の余白は sidebar 既定の行 inset が既に実測と 1 px 差で一致するため、ここでは足さない。
        .listRowBackground(
            Capsule(style: .continuous)
                .fill(padSelection == destination ? Color(.tertiarySystemFill) : Color.clear)
        )
        .accessibilityAddTraits(padSelection == destination ? .isSelected : [])
    }

    /// sidebar 下端に固定するアカウント行。参照では一覧が下を通り抜けるので、押し下げずに重ねる。
    private var padSidebarFooter: some View {
        Button {
            showsAccount = true
        } label: {
            HStack(spacing: 12) {
                AccountAvatar(name: accountName, size: 44)
                Text(accountName ?? String(localized: "ユーザー"))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            // 中身ではなく高さそのものを決める。アバターや名前が変わっても行の中心を動かさない。
            .frame(height: PadShell.sidebarFooterHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        // 基準の account 行は板の下端から 48 pt 上が中心。地は敷かず、一覧側の端の効果に任せる。
        .padding(.bottom, PadShell.sidebarFooterBottomPadding)
        .accessibilityIdentifier("sidebar.account")
    }

    private var accountName: String? {
        if case .signedIn(let user) = auth.state, !user.isEmpty { return user }
        return nil
    }

    @ViewBuilder
    private var padDetail: some View {
        switch padSelection {
        case .home:
            homeNavigation
        case .search:
            searchNavigation
        case .new:
            NavigationStack(path: $libraryPath) {
                AlbumGridView(title: String(localized: "新着"), albums: library.recentlyAdded)
            }
        case .radio:
            NavigationStack(path: $libraryPath) { RadioView() }
        case .favorites:
            NavigationStack(path: $libraryPath) { FavoriteTracksView() }
        case .unavailable(let screen):
            padUnavailableDetail(screen)
        case .pinned:
            // 固定そのものが Jellyfin に無いので、開くのは行の見た目ではなく「ピン」の未対応案内。
            padUnavailableDetail(.pins)
        case .recentlyAdded:
            NavigationStack(path: $libraryPath) {
                AlbumGridView(title: String(localized: "最近追加した項目"), albums: library.recentlyAdded)
            }
        case .albums:
            NavigationStack(path: $libraryPath) {
                AlbumGridView(title: String(localized: "アルバム"))
            }
        case .artists:
            NavigationStack(path: $libraryPath) { LibraryCollectionView(kind: .artists) }
        case .songs:
            NavigationStack(path: $libraryPath) { SongsView() }
        case .playlists:
            NavigationStack(path: $libraryPath) { LibraryCollectionView(kind: .playlists) }
        case .playlist(let playlist):
            NavigationStack(path: $libraryPath) { AlbumDetailView(album: playlist) }
        }
    }

    private func padUnavailableDetail(_ screen: PadUnavailable) -> some View {
        NavigationStack {
            ContentUnavailableView(
                screen.title,
                systemImage: screen.systemImage,
                description: Text("この項目は Jellyfin では扱えません。")
            )
            .navigationTitle(screen.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var homeNavigation: some View {
        NavigationStack(path: $homePath) {
            HomeView {
                if isPhonePlayer {
                    libraryPath = NavigationPath([LibraryRoute.albums])
                    selection = .library
                } else {
                    libraryPath = NavigationPath()
                    padSelection = .albums
                }
            }
        }
    }

    private var libraryNavigation: some View {
        NavigationStack(path: $libraryPath) { LibraryView() }
    }

    @ViewBuilder
    private var searchNavigation: some View {
        if isPhonePlayer {
            NavigationStack(path: $searchPath) { SearchView(query: $searchQuery) }
        } else {
            // iPad の automatic placement は split detail で検索欄を toolbar から完全に隠すため、
            // Search root だけ常時見える drawer に固定する。iPhone の search tab 配置は変えない。
            NavigationStack(path: $searchPath) {
                SearchView(query: $searchQuery)
                    .librarySearchable(
                        text: $searchQuery,
                        prompt: "アーティスト、曲、歌詞など",
                        horizontalMargin: 34.5
                    )
            }
        }
    }

    /// iPhone は UIKit のカスタム提示へ振る。`.large` detent が上端に 62 pt 空けるのを
    /// 修飾子では塞げないと結論が出ているため（仕様 4.1.1 章）。
    /// **幅の級では分けない。**Split View で狭くなった iPad が compact になるので、
    /// 幅で分けると仕様 4.1.1 章が「現状維持」と書いた iPad の中央 sheet までこちらへ来てしまう。
    /// 表示中に幅が変わっても経路が替わらないことにも意味があり、替わると一方の終了と他方の提示が
    /// 同時に走って、二つの Binding が `showsPlayer` へ false を書き戻し合う。
    private var isPhonePlayer: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// ミニプレイヤーを出しているか。積んだだけでは出さない条件は仕様 3 章のまま。
    private var showsMiniPlayer: Bool { player.currentItem != nil && hasStartedPlayback }

    private var padPlayerPresented: Binding<Bool> {
        Binding(get: { showsPlayer && !isPhonePlayer }, set: { showsPlayer = $0 })
    }

    private var customPlayerPresented: Binding<Bool> {
        Binding(get: { showsPlayer && isPhonePlayer }, set: { showsPlayer = $0 })
    }

    private var playerContent: some View {
        NowPlayingView(isScrubbing: $isScrubbing) { showsPlayer = false }
    }

    /// UIKit のカスタム提示は SwiftUI の環境を継がないので、本文が読む分を明示的に渡す。
    /// 今読んでいるのはこの 3 つだけで、増えたらここへ足す。**漏らすと実行時に落ちる**。
    private var customPlayerContent: some View {
        playerContent
            .environment(auth)
            .environment(library)
            .environment(player)
    }

}

#Preview {
    RootView()
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
        .environment(PlaybackSettings())
}
