import SwiftUI
import UIKit

/// アプリのルート。3 タブ + ミニプレイヤー + フルプレイヤー sheet（`docs/ui-spec.md` 1・3・4・6 章）。
struct RootView: View {
    private enum RootTab: Hashable { case home, library, search }

    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @Environment(PlaybackEngine.self) private var player
    @State private var catalog = AlbumCatalog()
    @State private var selection: RootTab = .home
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var searchQuery = ""
    @State private var showsPlayer = false
    /// シーク中だけ iPad の sheet の対話的な終了を止める（仕様 4.1 章）。状態は `NowPlayingView` が更新する。
    /// iPhone 側はこの値では止めない。カスタム提示の終了 pan がシーク認識器の失敗を待つ形に替えた
    /// ので、成立後に `isEnabled` を切り替える必要が無くなった（仕様 4.1.1 章）。
    @State private var isScrubbing = false
    /// 一度でも再生が始まったか。`currentItem` は「キューに追加」「次に再生」で積んだだけでも
    /// 埋まるので、これを併せないとミニプレイヤーが再生前から出る（仕様 3 章）。
    /// 本来は再生側が持つべき状態だが、`Musicfin/Player/` は指示なしに変えない決まりなので、
    /// 表示側で覚える暫定である。
    @State private var hasStartedPlayback = false
    /// ミニプレイヤーの矩形（窓座標）。「ミニプレイヤーから展開」方式の出発・帰着に渡す（仕様 4.1.1 章）。
    /// 報告してくるのは `MiniPlayerView` 自身なので、出ていない間は古い矩形が残る。渡す側で捨てる。
    @State private var miniPlayerFrame: CGRect?
    /// フルプレイヤーの開き方。**実機比較のための一時的な切り替え**で、設定画面と同じキーを読む。
    @AppStorage(PlayerPresentationStyle.storageKey) private var playerStyle = PlayerPresentationStyle.slideUp

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
            if showsMiniPlayer {
                MiniPlayerView(onFrameChange: { miniPlayerFrame = $0 }) { showsPlayer = true }
            }
        }
        // iPhone は UIKit のカスタム提示、iPad は中央 sheet（仕様 4.1.1 章・6 章）。
        // 端末で経路そのものが替わるので、同じ `showsPlayer` を二つの入口へ振り分ける。
        .sheet(isPresented: sheetPlayerPresented) { playerSheet }
        .playerPresentation(
            isPresented: customPlayerPresented,
            source: playerSource,
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
        .onChange(of: player.currentItem?.id) { _, id in
            if id == nil { showsPlayer = false }
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

    /// 展開の出発点。出していない間は矩形を渡さない。**渡すと居ない帯から広がって見える**。
    private var playerSource: CGRect? { showsMiniPlayer ? miniPlayerFrame : nil }

    private var sheetPlayerPresented: Binding<Bool> {
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

    /// iPad の中央 sheet（仕様 6 章）。狭い幅で効かせていた detent・角丸・適応の指定は
    /// カスタム提示側の仕事になったので、ここには残さない（仕様 4.1.1 章）。
    private var playerSheet: some View {
        playerContent
            // 幅の広い画面では 560 pt を目安にした中央の sheet（仕様 6 章）。
            .presentationSizing(.fitted)
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
            // 指示子は `NowPlayingView` が 60×5 pt を自分で描くので、システムのものは出さない（仕様 4 章）。
            .presentationDragIndicator(.hidden)
            // 終了を止めるのはシークが成立している間だけ。それ以外はシステムの終了へ任せる。
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
