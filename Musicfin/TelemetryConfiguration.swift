import Foundation

enum TelemetryConfiguration {
    static func isEnabled(in info: [String: Any]) -> Bool {
        #if DEBUG
        return false
        #else
        // 配信 CI の明示的な指定だけを許し、開発用の再インストールで収集設定を引き継がない。
        return info["MusicfinTelemetryEnabled"] as? String == "YES"
        #endif
    }
}
