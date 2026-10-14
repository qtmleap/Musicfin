import Foundation
import Observation

/// 計測 SDK の開始と停止。SDK を知る実装は別ファイルに分け、同意の判断だけを単体で検証できるようにする。
protocol TelemetryBackend: AnyObject {
    func start()
    func revoke()
}

/// 利用者の計測への同意。既定は OFF で、SDK 側に残った旧い状態（build 68 の固定値など）は参照しない。
@MainActor
@Observable
final class TelemetryConsent {
    static let choiceKey = "MusicfinTelemetryChoice.v1"

    /// 配信ビルド以外では保存値があっても収集しないため、画面側が操作可否を判断できるよう公開する。
    let isAvailable: Bool
    private(set) var isSharingEnabled: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backend: TelemetryBackend
    @ObservationIgnored private var isBackendRunning = false
    @ObservationIgnored private var didBootstrap = false

    init(defaults: UserDefaults = .standard, isDistribution: Bool, backend: TelemetryBackend) {
        self.defaults = defaults
        self.backend = backend
        isAvailable = isDistribution
        isSharingEnabled = isDistribution && defaults.bool(forKey: Self.choiceKey)
    }

    /// 起動時に一度だけ呼ぶ。保存済みの ON があるときだけ SDK を開始し、OFF なら SDK に一切触れない。
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        guard isSharingEnabled else { return }
        startBackendIfNeeded()
    }

    func setSharingEnabled(_ enabled: Bool) {
        guard isAvailable, enabled != isSharingEnabled || enabled != isBackendRunning else { return }
        // 選択を先に永続化し、SDK の処理が途中で終わっても次回起動は利用者の最新の選択に従う。
        defaults.set(enabled, forKey: Self.choiceKey)
        isSharingEnabled = enabled
        if enabled {
            startBackendIfNeeded()
        } else if isBackendRunning {
            isBackendRunning = false
            backend.revoke()
        }
    }

    private func startBackendIfNeeded() {
        guard !isBackendRunning else { return }
        isBackendRunning = true
        backend.start()
    }
}
