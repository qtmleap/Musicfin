import Foundation

nonisolated extension TimeInterval {
    /// 3:07 / 1:02:33 のような再生時間表記。
    var timeLabel: String {
        guard isFinite, self >= 0 else { return "--:--" }
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
    /// 「2023年・12曲」のようなアルバムの副題。
    var albumSubtitle: String {
        var parts: [String] = []
        if let year = productionYear { parts.append("\(year)年") }
        if let count = childCount { parts.append("\(count)曲") }
        return parts.joined(separator: "・")
    }
}
