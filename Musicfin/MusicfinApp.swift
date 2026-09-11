import SwiftUI

@main
struct MusicfinApp: App {
    @State private var auth = AuthStore()
    @State private var library = LibraryStore()
    @State private var player = PlaybackEngine()
    @State private var settings = PlaybackSettings()

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isSignedIn {
                    DesignVariant.current.rootView
                } else {
                    DesignVariant.current.loginView
                }
            }
            .environment(auth)
            .environment(library)
            .environment(player)
            .environment(settings)
            .task {
                // 音質は回線種別と組み合わせて曲ごとに決めるので、設定オブジェクトごとエンジンに渡す。
                player.configure(settings: settings)
                auth.restoreSession()
            }
            .onChange(of: auth.client) { _, client in
                library.configure(client: client)
                player.configure(client: client)
            }
        }
    }
}
