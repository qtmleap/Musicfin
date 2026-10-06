import Foundation

@main
struct LyricsFollowPolicyTests {
    static func main() {
        for active in 0...3 {
            expect(
                !canResume(active: active, visible: [4, 5, 6]),
                "a current timestamp before visible lyrics must preserve manual reading")
        }
        for active in [4, 5, 6, 7] {
            expect(
                !canResume(active: active, visible: [1, 2, 3]),
                "playback advancing offscreen must preserve manual reading")
        }
        expect(canResume(active: 4, visible: [3, 4, 5]), "a visible current line may resume after scrolling stops")
        expect(
            !canResume(active: 4, visible: [3, 4, 5], scrolling: true),
            "touch and inertia must never reacquire the viewport")
        expect(!canResume(active: nil, visible: [3, 4, 5]), "a hidden prelude must preserve manual reading")
        expect(canResume(active: nil, visible: [-1, 0, 1]), "a visible prelude may reacquire its native top position")
        expect(!canResume(active: nil, visible: [-1, 0, 1], synced: false), "untimed lyrics never follow playback")

        expect(blur(index: 0, active: nil) > 0, "initial prelude lyrics must be blurred")
        expect(blur(index: 4, active: 4) == 0, "the followed current lyric must stay crisp")
        expect(
            blur(index: 3, active: 4) > blur(index: 5, active: 4), "past lyrics must be more blurred than future lyrics"
        )
        for index in 0...8 {
            expect(blur(index: index, active: 4, following: false) == 0, "manual reading must clear every lyric's blur")
            expect(blur(index: index, active: nil, synced: false) == 0, "untimed lyrics must remain crisp")
            expect(
                blur(index: index, active: 4, reducedTransparency: true) == 0,
                "Reduce Transparency must clear decorative blur")
        }
        print(
            "LyricsFollowPolicy: offscreen reading, visible reacquisition, touch/inertia, prelude and asymmetric blur passed"
        )
    }

    private static func canResume(active: Int?, visible: Set<Int>, scrolling: Bool = false, synced: Bool = true) -> Bool
    {
        LyricsFollowPolicy.canReacquire(
            activeIndex: active, visibleIndices: visible, introID: -1, isSynced: synced, isUserScrolling: scrolling)
    }

    private static func blur(
        index: Int, active: Int?, following: Bool = true, synced: Bool = true, reducedTransparency: Bool = false
    ) -> Double {
        LyricsFollowPolicy.blurMultiplier(
            index: index, activeIndex: active, isSynced: synced, isFollowing: following,
            reduceTransparency: reducedTransparency)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("LyricsFollowPolicy failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
