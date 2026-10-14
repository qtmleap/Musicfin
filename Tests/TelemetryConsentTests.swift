import Foundation

// 同意の永続化と、SDK 境界(TelemetryBackend)への呼び出し回数を検証する。
private final class FakeBackend: TelemetryBackend {
    var startCount = 0
    var revokeCount = 0
    func start() { startCount += 1 }
    func revoke() { revokeCount += 1 }
}

@main
struct TelemetryConsentTests {
    static let key = "MusicfinTelemetryChoice.v1"

    @MainActor static var suiteNames: [String] = []

    @MainActor
    static func makeDefaults() -> UserDefaults {
        let name = "TelemetryConsentTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private static func make(_ defaults: UserDefaults, distribution: Bool = true) -> (TelemetryConsent, FakeBackend) {
        let backend = FakeBackend()
        return (TelemetryConsent(defaults: defaults, isDistribution: distribution, backend: backend), backend)
    }

    @MainActor
    static func main() {
        // 新規・旧 SDK のキーだけ残る更新では既定で OFF。SDK は一切呼ばない。
        let fresh = makeDefaults()
        fresh.set(true, forKey: "FIRAnalyticsEnabled")
        fresh.set(true, forKey: "firebase_crashlytics_collection_enabled")
        var (consent, backend) = make(fresh)
        consent.bootstrap()
        precondition(!consent.isSharingEnabled)
        precondition(backend.startCount == 0 && backend.revokeCount == 0)

        let earlyDefaults = makeDefaults()
        let (early, earlyBackend) = make(earlyDefaults)
        early.setSharingEnabled(true)
        early.bootstrap()
        precondition(early.isSharingEnabled && earlyBackend.startCount == 1, "early consent must start only once")

        // 明示 ON は再生成後も保持され、起動ごとに 1 回だけ開始する。
        let defaults = makeDefaults()
        (consent, backend) = make(defaults)
        consent.bootstrap()
        consent.setSharingEnabled(true)
        precondition(consent.isSharingEnabled && backend.startCount == 1)
        let (again, againBackend) = make(defaults)
        precondition(again.isSharingEnabled)
        again.bootstrap()
        again.bootstrap()
        precondition(againBackend.startCount == 1, "bootstrap must start once")

        // OFF は永続化され revoke される。同じ選択の繰り返しは何も起こさない。
        again.setSharingEnabled(true)
        precondition(againBackend.startCount == 1, "repeated ON is a no-op")
        again.setSharingEnabled(false)
        precondition(!again.isSharingEnabled && againBackend.revokeCount == 1)
        again.setSharingEnabled(false)
        precondition(againBackend.revokeCount == 1, "repeated OFF is a no-op")
        let (afterOff, offBackend) = make(defaults)
        afterOff.bootstrap()
        precondition(!afterOff.isSharingEnabled && offBackend.startCount == 0, "OFF relaunch must not start")

        // revoke 後の再 ON で実際に有効化される。同じインスタンスでも、設定は一度だけ・収集の有効化は毎回行う。
        again.setSharingEnabled(true)
        precondition(again.isSharingEnabled && againBackend.startCount == 2, "re-enable on the same instance")

        afterOff.setSharingEnabled(true)
        precondition(afterOff.isSharingEnabled && offBackend.startCount == 1)

        // 配信ビルドでなければ保存済み true を無視し、設定も受け付けない。
        let dev = makeDefaults()
        dev.set(true, forKey: key)
        let (devConsent, devBackend) = make(dev, distribution: false)
        devConsent.bootstrap()
        devConsent.setSharingEnabled(true)
        precondition(!devConsent.isSharingEnabled && devBackend.startCount == 0)

        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        print("TelemetryConsent: default-off, persistence, revoke and build gate passed")
    }
}
