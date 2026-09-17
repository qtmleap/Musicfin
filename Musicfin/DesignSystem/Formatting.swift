import Foundation

nonisolated extension TimeInterval {
    /// 3:07 / 1:02:33 のような再生時間表記。
    var timeLabel: String {
        // 桁の代わりに置く記号なので、ハイフンではなく数字と同じ字送りを持つ figure dash (U+2012)。
        // ハイフンだと 12 pt で字面 24.5 pt にしかならず、参照の 34.5 pt に対して細く見える（仕様 6.2.1 章）。
        guard isFinite, self >= 0 else { return "‒‒:‒‒" }
        let total = Int(rounded())
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// 残り時間の表記（先頭にマイナス）。
    var remainingLabel: String { "-" + timeLabel }
}

nonisolated extension MediaItem {
    /// 「2023年 · 12 曲」のようなアルバムの副題。
    /// 年も曲数も言語で語順や単複が変わるので、組み立てた文字列ではなくカタログを通す。
    var albumSubtitle: String {
        var parts: [String] = []
        if let year = productionYear { parts.append(String(localized: "\(year)年")) }
        if let count = childCount { parts.append(String(localized: "\(count) 曲")) }
        // 区切りは中黒（U+30FB）ではなく、Apple Music と同じ半角空白付きの中点（U+00B7）。
        // 英語表示で「2023・12 songs」と詰まって見えるのを避ける。
        return parts.joined(separator: " · ")
    }
}
