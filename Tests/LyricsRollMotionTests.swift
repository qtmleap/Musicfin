import Foundation

@main
struct LyricsRollMotionTests {
    static func main() {
        var motion = LyricsRollMotion(anchorIndex: 4, offset: 0, time: 0)
        motion.record(offset: 20, time: 0.1)
        motion.record(offset: 40, time: 0.2)
        let near = motion.compensation(for: 4, at: 0.2)
        let next = motion.compensation(for: 5, at: 0.2)
        let lower = motion.compensation(for: 8, at: 0.2)
        expect(near == 0, "the current line must move immediately")
        expect(next > near, "the next line must follow slightly later")
        expect(lower > next, "lower lines must follow later than nearby lines")
        expect(motion.compensation(for: 3, at: 0.2) == 0, "past lines must not trail behind")
        expect(motion.compensation(for: 80, at: 0.4) == 0, "even distant lines must catch up promptly")
        expect(motion.compensation(for: 8, at: 0.2, reduceMotion: true) == 0, "Reduce Motion removes the lag")

        let beforeAdvance = motion.compensation(for: 8, at: 0.2)
        motion.advance(to: 5, at: 0.2)
        expect(motion.compensation(for: 8, at: 0.2) == beforeAdvance, "a rapid advance must not jump lower lines")
        motion.record(offset: 50, time: 0.25)
        expect(motion.compensation(for: 8, at: 0.25) > 0, "rapid advances must retain the unfinished movement")
        motion.record(offset: 30, time: 0.3)
        expect(motion.compensation(for: 6, at: 0.3) < 0, "a spring returning from overshoot must retain its direction")
        motion.record(offset: .nan, time: 0.4)
        expect(motion.compensation(for: 6, at: 0.3).isFinite, "invalid geometry must not poison the movement")
        expect(motion.compensation(for: 6, at: 1) == 0, "a completed movement must leave no visual offset")

        for index in 1...500 {
            motion.record(offset: Double(index), time: 1 + Double(index) / 60)
        }
        expect(motion.compensation(for: 8, at: 10) == 0, "a long sequence must still settle to its native position")

        expect(shouldRoll(from: 1, to: 2, oldTime: 10, time: 10.2), "normal playback must roll")
        expect(shouldRoll(from: 1, to: 3, oldTime: 10, time: 10.2), "closely timed lines may advance together")
        expect(!shouldRoll(from: 1, to: 2, oldTime: 10, time: 16), "a forward seek must align directly")
        expect(!shouldRoll(from: 2, to: 1, oldTime: 10, time: 5), "a backward seek must align directly")
        expect(!shouldRoll(from: nil, to: 0, oldTime: 10, time: 10.2), "initial alignment must not trail")
        expect(!shouldRoll(from: 1, to: 2, oldTime: 10, time: 10.2, playing: false), "paused seeking must not roll")
        expect(!shouldRoll(from: 1, to: 2, oldTime: 10, time: 10.2, reduced: true), "Reduce Motion must align directly")
        print(
            "LyricsRollMotion: nearby response, lower-line delay, settling, overlapping advances, spring return and seeking passed"
        )
    }

    private static func shouldRoll(
        from: Int?, to: Int?, oldTime: Double, time: Double, playing: Bool = true, reduced: Bool = false
    ) -> Bool {
        LyricsRollMotion.shouldRoll(
            from: from, to: to, previousPosition: oldTime, position: time, isPlaying: playing, reduceMotion: reduced)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("LyricsRollMotion failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
