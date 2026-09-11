import SwiftUI

/// タブごとの戻り先を保ち、アルバムカタログだけを共有して重複取得を防ぐ。
struct AstraRootView: View {
    private enum AstraRootTab: Hashable { case home, library, search }
    @Environment(PlaybackEngine.self) private var player
    @State private var catalog = AlbumCatalog()
    @State private var selection: AstraRootTab = .home
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var showsPlayer = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("ホーム", systemImage: "house", value: .home) {
                NavigationStack(path: $homePath) {
                    AstraHomeView {
                        libraryPath = NavigationPath([AstraLibraryRoute.albums])
                        selection = .library
                    }
                }
            }
            Tab("ライブラリ", systemImage: "square.stack", value: .library) {
                NavigationStack(path: $libraryPath) { AstraLibraryView() }
            }
            Tab("検索", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack(path: $searchPath) { AstraSearchView() }
            }
        }
        .environment(catalog)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if player.currentItem != nil {
                AstraMiniPlayerView { showsPlayer = true }
            }
        }
        .sheet(isPresented: $showsPlayer) {
            AstraNowPlayingView()
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
    AstraRootView()
        .environment(AuthStore())
        .environment(LibraryStore())
        .environment(PlaybackEngine())
        .environment(PlaybackSettings())
        .environment(AlbumCatalog())
}
