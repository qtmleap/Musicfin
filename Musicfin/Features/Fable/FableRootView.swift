import SwiftUI

/// Fable 版のルート。3 タブ + ミニプレイヤー + フルプレイヤー sheet（`docs/ui-spec.md` 1・3・4・6 章）。
struct FableRootView: View {
    private enum FableRootTab: Hashable { case home, library, search }

    @Environment(PlaybackEngine.self) private var player
    @State private var catalog = AlbumCatalog()
    @State private var selection: FableRootTab = .home
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var showsPlayer = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("ホーム", systemImage: "house", value: .home) {
                NavigationStack(path: $homePath) {
                    FableHomeView {
                        libraryPath = NavigationPath([FableLibraryRoute.albums])
                        selection = .library
                    }
                }
            }
            Tab("ライブラリ", systemImage: "square.stack", value: .library) {
                NavigationStack(path: $libraryPath) { FableLibraryView() }
            }
            Tab("検索", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack(path: $searchPath) { FableSearchView() }
            }
        }
        // ログイン・設定と同じピンクを操作色にして、リンク・選択中タブ・再生中表示まで統一する。
        .tint(.pink)
        .environment(catalog)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if player.currentItem != nil {
                FableMiniPlayerView { showsPlayer = true }
            }
        }
        .sheet(isPresented: $showsPlayer) {
            FableNowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        }
        .onChange(of: player.currentItem?.id) { _, id in
            if id == nil { showsPlayer = false }
        }
    }
}

#Preview {
    FableRootView()
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
        .environment(PlaybackSettings())
}
