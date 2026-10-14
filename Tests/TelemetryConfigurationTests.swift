import Foundation

@main
struct TelemetryConfigurationTests {
    static func main() {
        let disabledInputs: [[String: Any]] = [
            [:], ["MusicfinTelemetryEnabled": "NO"], ["MusicfinTelemetryEnabled": "true"],
            ["MusicfinTelemetryEnabled": true], ["MusicfinTelemetryEnabled": "YES "],
        ]
        let yes: [String: Any] = ["MusicfinTelemetryEnabled": "YES"]
        for input in disabledInputs {
            for consent in [false, true] {
                precondition(
                    !TelemetryConfiguration.isEnabled(in: input, hasConsent: consent),
                    "unconfigured builds must not collect")
            }
        }
        #if DEBUG
        for consent in [false, true] {
            precondition(
                !TelemetryConfiguration.isEnabled(in: yes, hasConsent: consent),
                "Debug builds must not collect even with the distribution flag and consent")
        }
        #else
        // 配信フラグだけでは収集せず、利用者の明示的な同意を必須にする。
        precondition(!TelemetryConfiguration.isEnabled(in: yes), "default must stay off")
        precondition(
            !TelemetryConfiguration.isEnabled(in: yes, hasConsent: false),
            "distribution flag without user consent must stay off")
        precondition(
            TelemetryConfiguration.isEnabled(in: yes, hasConsent: true), "flag and consent must enable collection")
        #endif
        print("TelemetryConfiguration: distribution opt-in, consent and development isolation passed")
    }
}
