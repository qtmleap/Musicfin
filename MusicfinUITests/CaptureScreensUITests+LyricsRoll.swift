import Foundation
import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testLyricsRollPlaybackAndManualRecovery() {
        launchApp()
        ensureSignedIn()
        captureReplyPlayerScreens(onLyricsReady: {
            guard let play = self.firstHittableElement(in: self.app.buttons.matching(identifier: "Play"), timeout: 10)
            else {
                XCTFail("歌詞送りを始める再生ボタンが見つからなかった")
                return
            }
            play.tap()
            let second = self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "優しい思い出")).firstMatch
            let third = self.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "さわれない")).firstMatch
            // 対象の Reply は先頭行から約12秒で次へ進む。送りの間は階層の照会を避け、
            // 録画した行の位置差を観察できるようにしてから選択を確かめる。
            for (line, name, delay) in [
                (second, "lyrics-roll-second-line", 12.5), (third, "lyrics-roll-third-line", 3.5),
            ] {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: delay))
                let selected = self.expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: line)
                guard XCTWaiter.wait(for: [selected], timeout: 30) == .completed else {
                    XCTFail("再生に合わせて次の歌詞へ進まなかった")
                    return
                }
                self.capture(name)
            }
            guard let pause = self.firstHittableElement(in: self.app.buttons.matching(identifier: "Pause"), timeout: 10)
            else {
                XCTFail("歌詞送りの後で一時停止できなかった")
                return
            }
            pause.tap()
            self.settle()
            let alignedY = third.frame.midY
            // 遅れを残したまま指操作へ入ると引っ掛かるため、現在行が見えたまま読み戻し、
            // 指と慣性が終わった時点で追従を取り直すことを確かめる。
            let origin = third.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            origin.press(
                forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: 80)),
                withVelocity: .slow, thenHoldForDuration: 0)
            self.settle()
            XCTAssertTrue(third.isSelected, "手動スクロールで現在行の選択が失われた")
            XCTAssertEqual(third.frame.midY, alignedY, accuracy: 3, "可視の現在行へ停止後すぐ追従を取り直さなかった")
            self.capture("lyrics-roll-resumed")
        })
        XCTAssertTrue(skippedScreens.isEmpty)
    }
}
