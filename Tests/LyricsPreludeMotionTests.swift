import Foundation

@main
struct LyricsPreludeMotionTests {
    static func main() {
        let start = LyricsPreludeMotion.at(position: 0, lyricStart: 30)
        expect(start.scale == 1 && start.dotOpacities == [1, 1, 1], "initial reference appearance")
        let breathing = LyricsPreludeMotion.at(position: 2, lyricStart: 30)
        expect(breathing.scale > start.scale, "dots must breathe while playback advances")

        let early = LyricsPreludeMotion.at(position: 5, lyricStart: 30)
        let middle = LyricsPreludeMotion.at(position: 15, lyricStart: 30)
        let late = LyricsPreludeMotion.at(position: 25, lyricStart: 30)
        expect(early.dotOpacities[0] > early.dotOpacities[1], "left dot lights first")
        expect(middle.dotOpacities[0] > middle.dotOpacities[1], "left dot completes before middle")
        expect(middle.dotOpacities[1] > middle.dotOpacities[2], "middle dot lights before right")
        expect(late.dotOpacities[2] > early.dotOpacities[2], "right dot follows prelude progress")

        let ending = LyricsPreludeMotion.at(position: 29.9, lyricStart: 30)
        let ended = LyricsPreludeMotion.at(position: 30, lyricStart: 30)
        expect(ending.opacity > 0 && ending.opacity < 1, "dots fade before the first lyric")
        expect(ending.scale < late.scale, "dots shrink into the first lyric")
        expect(ended.opacity == 0, "dots vanish at the lyric timestamp")
        for position in [2.0, 15, 29.9] {
            expect(
                LyricsPreludeMotion.at(position: position, lyricStart: 30, reduceMotion: true).scale == 1,
                "Reduce Motion disables breathing and shrinking")
        }

        let now = Date(timeIntervalSince1970: 100)
        let clock = LyricsPreludeClock(position: 5, sampledAt: now)
        expect(clock.presentationPosition(at: now.addingTimeInterval(10), advancing: false) == 5, "pause freezes time")
        let advanced = clock.presentationPosition(at: now.addingTimeInterval(0.1), advancing: true)
        expect(advanced > 5 && advanced < 5.2, "smooth time between player samples")
        expect(
            clock.presentationPosition(at: now.addingTimeInterval(10), advancing: true) < 5.5,
            "stalled time stays bounded")
        expect(
            clock.presentationPosition(at: now.addingTimeInterval(-1), advancing: true) == 5,
            "clock cannot run backwards")
        let sought = LyricsPreludeClock(position: 0, sampledAt: now.addingTimeInterval(2))
        expect(
            sought.presentationPosition(at: now.addingTimeInterval(2), advancing: true) == 0,
            "seek resets the motion clock")
        print(
            "LyricsPreludeMotion: breathing, sequential lighting, exit, reduced motion, pause, stalled time and seek passed"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("LyricsPreludeMotion failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
