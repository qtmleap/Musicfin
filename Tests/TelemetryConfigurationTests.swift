import Foundation

@main
struct TelemetryConfigurationTests {
    static func main() {
        let disabledInputs: [[String: Any]] = [
            [:], ["MusicfinTelemetryEnabled": "NO"], ["MusicfinTelemetryEnabled": "true"],
            ["MusicfinTelemetryEnabled": true], ["MusicfinTelemetryEnabled": "YES "],
        ]
        for input in disabledInputs {
            precondition(!TelemetryConfiguration.isEnabled(in: input), "unconfigured builds must not collect")
        }
        #if DEBUG
        precondition(
            !TelemetryConfiguration.isEnabled(in: ["MusicfinTelemetryEnabled": "YES"]),
            "Debug builds must not collect even with the distribution flag")
        #else
        precondition(
            TelemetryConfiguration.isEnabled(in: ["MusicfinTelemetryEnabled": "YES"]),
            "distribution builds must enable collection")
        #endif
        print("TelemetryConfiguration: distribution opt-in and development isolation passed")
    }
}
