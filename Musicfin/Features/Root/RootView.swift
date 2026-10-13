import SwiftUI

struct RootView: View {
    private enum RootTab: Hashable { case home, library, search }
    @Environment(PlaybackEngine.self) private var player
    @State private var catalog = AlbumCatalog()
    @State private var selection: RootTab = .home
    @State private var homePath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var showsPlayer = false

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
                NavigationStack(path: $searchPath) { SearchView() }
            }
        }
        .environment(catalog)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            if player.currentItem != nil {
                MiniPlayerView { showsPlayer = true }
            }
        }
        .sheet(isPresented: $showsPlayer) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        }
        .onChange(of: player.currentItem?.id) { _, id in
            if id == nil { showsPlayer = false }
        }
    }
}
