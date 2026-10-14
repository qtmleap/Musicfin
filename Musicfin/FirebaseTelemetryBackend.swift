import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import Foundation

/// 同意が ON のときだけ Firebase を生成する。OFF の間は `FirebaseApp.configure()` を含め API を一切呼ばない。
final class FirebaseTelemetryBackend: TelemetryBackend {
    func start() {
        // 設定は起動ごとに一度だけ。撤回後の再 ON では収集の有効化だけをやり直す。
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        Analytics.setConsent([
            .analyticsStorage: .granted,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied,
        ])
        Analytics.setAnalyticsCollectionEnabled(true)
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
    }

    func revoke() {
        // 未設定なら Firebase を生成してしまうので、触らない。
        guard FirebaseApp.app() != nil else { return }
        Analytics.setAnalyticsCollectionEnabled(false)
        Analytics.setConsent([
            .analyticsStorage: .denied,
            .adStorage: .denied,
            .adUserData: .denied,
            .adPersonalization: .denied,
        ])
        Analytics.resetAnalyticsData()
        // Crashlytics の停止は次回起動から完全に効く。送信中や送信済みの報告は取り消せない。
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.setCrashlyticsCollectionEnabled(false)
        // 起動時に既に許可された送信は取り消せないため、SDK が未送信として扱う報告だけ削除を求める。
        crashlytics.deleteUnsentReports()
    }
}

extension TelemetryConsent {
    /// アプリ全体で共有する唯一の同意。AppDelegate と画面が同じ状態を見る。
    static let live = TelemetryConsent(
        isDistribution: TelemetryConfiguration.isEnabled(in: Bundle.main.infoDictionary ?? [:], hasConsent: true),
        backend: FirebaseTelemetryBackend()
    )
}
