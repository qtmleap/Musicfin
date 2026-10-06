import Foundation

nonisolated struct LyricsPreludeMotion: Equatable, Sendable {
    var scale = 1.0
    var opacity = 1.0
    var dotOpacities = [1.0, 1.0, 1.0]

    static func at(position: TimeInterval, lyricStart: TimeInterval, reduceMotion: Bool = false) -> Self {
        guard position.isFinite, lyricStart.isFinite, lyricStart > 0 else {
            return Self(opacity: 0)
        }
        let time = min(max(0, position), lyricStart)
        let remaining = lyricStart - time
        let progress = time / lyricStart * 3
        // 0:00 の参照では3点とも白い。再生開始で急に暗転させず、進捗の濃淡へ短くなじませる。
        let entrance = smooth(time / min(0.35, lyricStart / 4))
        let dots = (0..<3).map { index in
            let target = 0.3 + 0.7 * clamp(progress - Double(index))
            return 1 + (target - 1) * entrance
        }
        var scale = breathing(at: time)
        var opacity = 1.0
        // 歌詞までの時間が短い曲でも、始めた瞬間から退場に入らないよう終端の長さを縮める。
        let exitDuration = min(0.75, lyricStart / 2)
        let fadeDuration = min(0.25, lyricStart / 3)
        if remaining <= fadeDuration {
            let visible = smooth(remaining / fadeDuration)
            scale = 0.4 + 0.72 * visible
            opacity = visible
        } else if remaining < exitDuration {
            let prepare = smooth((exitDuration - remaining) / (exitDuration - fadeDuration))
            let base = breathing(at: lyricStart - exitDuration)
            scale = base + (1.12 - base) * prepare
        }
        return Self(scale: reduceMotion ? 1 : scale, opacity: opacity, dotOpacities: dots)
    }

    private static func breathing(at time: TimeInterval) -> Double {
        1 + 0.08 * (1 - cos(time * 2 * .pi / 4)) / 2
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func smooth(_ value: Double) -> Double {
        let fraction = clamp(value)
        return fraction * fraction * (3 - 2 * fraction)
    }
}

nonisolated struct LyricsPreludeClock: Equatable, Sendable {
    let position: TimeInterval
    let sampledAt: Date

    func presentationPosition(at date: Date, advancing: Bool) -> TimeInterval {
        guard advancing else { return position }
        // Player の通知は0.2秒間隔。通知の間だけ補間し、通信待ちで通知が止まっても時計を走らせ続けない。
        return position + min(max(0, date.timeIntervalSince(sampledAt)), 0.25)
    }
}
