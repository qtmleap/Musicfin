import Foundation

enum TelemetryConfiguration {
    static func isEnabled(in info: [String: Any], hasConsent: Bool = false) -> Bool {
        #if DEBUG
        return false
        #else
        // 配信 CI の明示指定に加えて利用者の同意を必須にし、フラグだけでは収集しない。
        return info["MusicfinTelemetryEnabled"] as? String == "YES" && hasConsent
        #endif
    }
}
