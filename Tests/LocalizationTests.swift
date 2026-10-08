import Foundation

@main
struct LocalizationTests {
    struct DatedValue: Decodable {
        let date: Date
    }

    @MainActor static func main() throws {
        let english = CommandLine.arguments[1] == "en"
        precondition(Bundle.main.preferredLocalizations.first == (english ? "en" : "ja"))
        precondition(String(localized: "前奏") == (english ? "Intro" : "前奏"))
        precondition(String(localized: "ロスレス") == (english ? "Lossless" : "ロスレス"))

        let item = MediaItem(id: "track", artists: ["A", "B"])
        precondition(item.displayArtist == (english ? "A, B" : "A、B"))
        let tagged = MediaItem(
            id: "tagged", artistItems: [NameIdPair(id: "a", name: "A"), NameIdPair(id: "b", name: "B")])
        precondition(tagged.displayArtist == item.displayArtist)
        precondition(MediaItem(id: "solo", artists: ["A"]).displayArtist == "A")
        precondition(
            MediaItem(id: "fallback", albumArtist: "Album Artist", artists: []).displayArtist == "Album Artist")

        let diagnostic = "RAW_DIAGNOSTIC_日本語"
        let decoding = JellyfinError.decoding(underlying: diagnostic)
        let transport = JellyfinError.transport(underlying: diagnostic)
        precondition(decoding.errorDescription == String(localized: "サーバーの応答を解釈できませんでした。"))
        precondition(transport.errorDescription == String(localized: "サーバーに接続できませんでした。"))
        if case .decoding(let retained) = decoding { precondition(retained == diagnostic) }
        if case .transport(let retained) = transport { precondition(retained == diagnostic) }
        precondition(JellyfinError.http(status: 503, body: "Server body").errorDescription?.contains("503") == true)
        precondition(
            JellyfinError.http(status: 503, body: "Server body").errorDescription?.contains("Server body") == true)

        do {
            _ = try JellyfinCoding.decoder.decode(DatedValue.self, from: Data(#"{"Date":"invalid-date"}"#.utf8))
            preconditionFailure("Invalid date was accepted")
        } catch DecodingError.dataCorrupted(let context) {
            precondition(
                context.debugDescription
                    == (english ? "Could not parse a date: invalid-date" : "日付として解釈できません: invalid-date"))
        }
        print(
            "Localization: \(english ? "en" : "ja") artist names, intro, lossless, error summaries and retained diagnostics passed"
        )
    }
}
