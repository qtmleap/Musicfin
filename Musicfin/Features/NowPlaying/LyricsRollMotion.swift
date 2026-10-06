import Foundation

nonisolated struct LyricsRollMotion {
    private struct Sample {
        var time: TimeInterval
        var offset: Double
    }

    private var samples: [Sample]
    private var anchorStart: Double
    private var anchorTarget: Double
    private var anchorChangedAt: TimeInterval

    init(anchorIndex: Int, offset: Double, time: TimeInterval) {
        samples = [Sample(time: time, offset: offset)]
        anchorStart = Double(anchorIndex)
        anchorTarget = Double(anchorIndex)
        anchorChangedAt = time
    }

    mutating func advance(to index: Int, at time: TimeInterval) {
        // 短い歌詞が続いても、まだ追いついていない行の遅れを突然切り替えて跳ねさせない。
        anchorStart = anchor(at: time)
        anchorTarget = Double(index)
        anchorChangedAt = time
    }

    mutating func record(offset: Double, time: TimeInterval) {
        guard offset.isFinite, time.isFinite, let last = samples.last, time >= last.time else { return }
        if time == last.time {
            samples[samples.count - 1].offset = offset
        } else {
            samples.append(Sample(time: time, offset: offset))
        }
        // 必要なのは最大150ms前の位置。補間の手前を1点残し、長い連続送りでも履歴を増やし続けない。
        while samples.count > 2, samples[1].time < time - 0.25 {
            samples.removeFirst()
        }
    }

    func compensation(for index: Int, at time: TimeInterval, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion, time.isFinite, let last = samples.last else { return 0 }
        let now = max(time, last.time)
        let delay = min(max(0, Double(index) - anchor(at: now)) * 0.03, 0.15)
        return last.offset - offset(at: now - delay)
    }

    private func anchor(at time: TimeInterval) -> Double {
        let progress = min(max(0, (time - anchorChangedAt) / 0.08), 1)
        let eased = progress * progress * (3 - 2 * progress)
        return anchorStart + (anchorTarget - anchorStart) * eased
    }

    private func offset(at time: TimeInterval) -> Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        if time <= first.time { return first.offset }
        for index in 1..<samples.count {
            let next = samples[index]
            guard time <= next.time else { continue }
            let previous = samples[index - 1]
            let progress = (time - previous.time) / (next.time - previous.time)
            return previous.offset + (next.offset - previous.offset) * progress
        }
        return last.offset
    }

    static func shouldRoll(
        from previousIndex: Int?, to index: Int?, previousPosition: TimeInterval, position: TimeInterval,
        isPlaying: Bool, reduceMotion: Bool
    ) -> Bool {
        guard isPlaying, !reduceMotion, let previousIndex, let index, index > previousIndex,
            previousPosition.isFinite, position.isFinite
        else { return false }
        let elapsed = position - previousPosition
        // 再生の0.2秒通知を許容し、大きく飛ぶシークと逆送りは既存の位置合わせに任せる。
        return elapsed > 0 && elapsed <= 0.5
    }
}
