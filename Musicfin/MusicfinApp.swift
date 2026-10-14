import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import SwiftUI
import UIKit

@main
struct MusicfinApp: App {
    @UIApplicationDelegateAdaptor(MusicfinAppDelegate.self) private var appDelegate
    @State private var auth = AuthStore()
    @State private var library = LibraryStore()
    @State private var player = PlaybackEngine()
    @State private var settings = PlaybackSettings()

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isSignedIn {
                    RootView()
                } else {
                    LoginView()
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

private final class MusicfinAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard TelemetryConfiguration.isEnabled(in: Bundle.main.infoDictionary ?? [:]) else { return true }

        FirebaseApp.configure()
        Analytics.setConsent([
            .analyticsStorage: .granted,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied,
        ])
        Analytics.setAnalyticsCollectionEnabled(true)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        return true
    }
}
