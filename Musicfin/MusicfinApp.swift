import SwiftUI

@main
struct MusicfinApp: App {
    @State private var auth = AuthStore()
    @State private var library = LibraryStore()
    @State private var player = PlaybackEngine()

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isSignedIn {
                    NavigationStack { SearchView() }
                } else {
                    LoginView()
                }
            }
            .environment(auth)
            .environment(library)
            .environment(player)
            .task { auth.restoreSession() }
            .onChange(of: auth.client) { _, client in
                library.configure(client: client)
                player.configure(client: client)
            }
        }
    }
}
