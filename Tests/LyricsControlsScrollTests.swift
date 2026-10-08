import Foundation

@main
struct LyricsControlsScrollTests {
    static func main() {
        var controls = LyricsControlsScroll()
        _ = controls.observeOffset(0, isDecelerating: false)
        _ = controls.drag(to: 0)
        expect(controls.drag(to: -40) == true, "reading forward must hide the controls once")

        // 同じ上向きの実指で記録された逆向き補正。高さ変更と別の通知で届くため、位置だけでは見分けられない。
        for offset in [58.67, 54.0, 63.67, 54.0, 82.0, 57.0] {
            expect(
                controls.observeOffset(offset, isDecelerating: false) == nil,
                "layout corrections must not reverse the gesture")
        }
        expect(controls.isHidden, "the recorded feedback must leave the controls hidden")
        expect(controls.drag(to: -70) == nil, "continuing the same gesture must not toggle the controls")
        expect(controls.drag(to: -50) == false, "a real reversal during layout animation must show the controls")
        expect(!controls.isHidden, "the real finger direction must win over geometry")

        controls.endDragging()
        _ = controls.observeOffset(100, isDecelerating: false)
        expect(
            controls.observeOffset(160, isDecelerating: true) == nil, "inertia cannot reverse the last finger direction"
        )
        expect(
            controls.observeOffset(140, isDecelerating: true) == nil, "matching inertia must retain visible controls")
        controls.stop()

        var momentum = LyricsControlsScroll()
        _ = momentum.observeOffset(100, isDecelerating: false)
        _ = momentum.drag(to: 0)
        _ = momentum.drag(to: -20)
        momentum.endDragging()
        expect(
            momentum.observeOffset(112, isDecelerating: true) == true,
            "finger movement and ensuing inertia share the threshold")
        expect(
            momentum.observeOffset(80, isDecelerating: true) == nil,
            "a layout correction during inertia cannot show controls")
        expect(momentum.isHidden, "inertial corrections must not restart the feedback loop")
        momentum.stop()
        expect(
            momentum.observeOffset(0, isDecelerating: false, allowTopShortcut: true) == nil,
            "an idle resize to zero is not reading back")

        var short = LyricsControlsScroll()
        _ = short.drag(to: 0)
        expect(short.drag(to: -33) == true, "lyrics with no scroll range still follow actual finger movement")
        expect(
            short.observeOffset(0, isDecelerating: false, layoutChanged: true, allowTopShortcut: true) == nil,
            "viewport growth must not restore short lyrics controls")
        expect(short.drag(to: -15, isAtTop: true) == false, "reading short lyrics back must restore the controls")

        var cancelled = LyricsControlsScroll()
        _ = cancelled.observeOffset(100, isDecelerating: false)
        _ = cancelled.drag(to: 0)
        _ = cancelled.drag(to: -40)
        _ = cancelled.drag(to: -32)
        expect(cancelled.isDragging, "a live drag owns its translation")
        cancelled.stop()
        expect(!cancelled.isDragging, "cancellation must release translation ownership without onEnded")
        expect(cancelled.isHidden, "cancellation must not change the control visibility")
        expect(
            cancelled.observeOffset(50, isDecelerating: true) == nil,
            "cancelled movement must not authorize later inertia")
        expect(cancelled.drag(to: 0) == nil, "a new gesture must establish a fresh origin after cancellation")
        expect(cancelled.drag(to: 8) == nil, "the cancelled gesture must not enlarge a small reversal")
        expect(cancelled.drag(to: 17) == false, "a fresh deliberate reversal must still restore controls")

        print(
            "LyricsControlsScroll: resize feedback, reversal, inertia, cancellation, idle geometry and short lyrics passed"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("LyricsControlsScroll failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
