import SwiftUI

/// アプリのルート。3 タブ + ミニプレイヤー + フルプレイヤー sheet（`docs/ui-spec.md` 1・3・4・6 章）。
struct RootView: View {
    private enum RootTab: Hashable { case home, library, search }

    @Environment(PlaybackEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var catalog = AlbumCatalog()
    @State private var selection: RootTab = .home
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchQuery = ""
    @State private var showsPlayer = false
    /// シーク中だけ sheet の対話的な終了を止める（仕様 4.1 章）。状態は `NowPlayingView` が更新する。
    @State private var isScrubbing = false
    /// 一度でも再生が始まったか。`currentItem` は「キューに追加」「次に再生」で積んだだけでも
    /// 埋まるので、これを併せないとミニプレイヤーが再生前から出る（仕様 3 章）。
    /// 本来は再生側が持つべき状態だが、`Musicfin/Player/` は指示なしに変えない決まりなので、
    /// 表示側で覚える暫定である。
    @State private var hasStartedPlayback = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("ホーム", systemImage: "house", value: .home) {
                NavigationStack(path: $homePath) {
                    HomeView {
                        libraryPath = NavigationPath([LibraryRoute.albums])
                        selection = .library
                    }
                }
            }
            Tab("ライブラリ", systemImage: "square.stack", value: .library) {
                NavigationStack(path: $libraryPath) { LibraryView() }
            }
            Tab("検索", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack(path: $searchPath) { SearchView(query: $searchQuery) }
            }
        }
        // 検索タブの入力欄はタブバーの位置に出す。画面側に付けるとナビゲーションバーへ積まれ、
        // 画面名とタイルがその分だけ下がる（仕様 1 章）。
        .searchable(text: $searchQuery, prompt: "アーティスト、曲、歌詞など")
        // ログイン・設定と同じピンクを操作色にして、リンク・選択中タブ・再生中表示まで統一する。
        .tint(.pink)
        .environment(catalog)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if player.currentItem != nil, hasStartedPlayback {
                MiniPlayerView { showsPlayer = true }
            }
        }
        .sheet(isPresented: $showsPlayer) { playerSheet }
        // `initial: true` が要る。この画面が作り直されたときに既に再生中だと、値が真のまま変化せず
        // 通知が来ないので、再生中なのにミニプレイヤーが出ないまま取り残される。
        .onChange(of: player.isPlaying, initial: true) { _, isPlaying in
            if isPlaying { hasStartedPlayback = true }
        }
        // 待ち行列が空になったら忘れる（仕様 3 章）。次に積んだだけの曲でまた出てしまわないように。
        .onChange(of: player.queue.isEmpty) { _, isEmpty in
            if isEmpty { hasStartedPlayback = false }
        }
        .onChange(of: player.currentItem?.id) { _, id in
            if id == nil { showsPlayer = false }
        }
    }

    /// 狭い幅のときだけ `.large` の detent を与える（仕様 4.1 章）。
    /// 広い幅で外しているのは 6 章の中央 sheet を意図してのことだが、
    /// `presentationSizing(.fitted)` と `presentationDetents` を併せたときどちらが勝つかは確かめていない。
    /// 広い幅でも付けて構わないかは、実機で大きさを見るまで分からない。
    @ViewBuilder
    private var playerSheet: some View {
        if horizontalSizeClass == .compact {
            playerContent.presentationDetents([.large])
        } else {
            playerContent
        }
    }

    private var playerContent: some View {
        NowPlayingView(isScrubbing: $isScrubbing)
            // 幅の広い画面では 560 pt を目安にした中央の sheet（仕様 6 章）。
            .presentationSizing(.fitted)
            // 狭い幅でも全画面へ適応させない。上部の角丸と、指に追従する下スワイプを
            // システムから受け取るため（仕様 4.1 章 第 2 版）。
            .presentationCompactAdaptation(.none)
            // 角丸の値は自分で決めず、システム既定に委ねる（仕様 4.1 章）。
            .presentationCornerRadius(nil)
            // 提示領域そのものの地。`NowPlayingView` 側の背景が届かない外周まで塞ぐ。
            // 既定のままだと外周だけ黒へ戻るので、同じ帯・同じ曲から同じ色を引く（仕様 1.2 章）。
            // 色を `NowPlayingView` から受け取らず、ここでもう一度取り出しているのは、
            // sheet の中から提示領域の地を塗る経路が無いため。画像はキャッシュ済みで走査は 32×32 なので、
            // 二度引いても同じ値が同じ速さで出る。
            .presentationBackground {
                ArtworkBackdrop(
                    item: player.currentItem,
                    band: .player,
                    artworkSize: NowPlayingView.paletteArtworkSize
                ) { _ in
                    Color.clear
                }
            }
            // グラバーは自前で描かず、システムの指示子を出す（仕様 4.1 章 第 2 版）。
            .presentationDragIndicator(.visible)
            // 本文のスクロールを提示サイズの変更より優先する（仕様 4.1 章）。
            .presentationContentInteraction(.scrolls)
            // 終了を止めるのはシークが成立している間だけ。それ以外は指に追従する終了へ任せる。
            .interactiveDismissDisabled(isScrubbing)
    }
}

#Preview {
    RootView()
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
        .environment(PlaybackSettings())
}
