import Foundation
import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testPreludeAnimationFollowsPlayback() {
        launchApp()
        ensureSignedIn()
        captureReplyPlayerScreens {
            let intro = self.app.descendants(matching: .any)
                .matching(identifier: "lyrics.intro-placeholder").firstMatch
            // iPad では背面のミニプレイヤーも同じラベルを持つため、表示中の操作だけを選ぶ。
            guard let play = self.firstHittableElement(in: self.app.buttons.matching(identifier: "Play"), timeout: 10)
            else {
                XCTFail("表示中の再生ボタンが見つからなかった")
                return
            }
            // 時計や歌詞本文の変化で「動いた」と誤判定せず、拡縮しても収まる丸の周囲だけを比べる。
            let region = intro.frame.insetBy(dx: -10, dy: -10)
            do {
                let initial = try self.lyricsIntroFrame(in: region)
                play.tap()
                var frames: Set<Data> = []
                for _ in 0..<6 {
                    frames.insert(try self.lyricsIntroFrame(in: region))
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.17))
                }
                XCTAssertGreaterThan(frames.count, 1, "再生中も前奏のドットが静止したまま")
                let pause = try XCTUnwrap(
                    self.firstHittableElement(in: self.app.buttons.matching(identifier: "Pause"), timeout: 10))
                pause.tap()
                self.settle()
                let paused = try self.lyricsIntroFrame(in: region)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.7))
                XCTAssertEqual(try self.lyricsIntroFrame(in: region), paused, "一時停止してもドットが動き続けた")

                let seek = self.app.otherElements.matching(
                    NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
                ).firstMatch
                seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                    forDuration: 0.05,
                    thenDragTo: seek.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5)))
                self.settle()
                XCTAssertEqual(try self.lyricsIntroFrame(in: region), initial, "シーク後に前奏の進み具合が戻らなかった")
            } catch {
                XCTFail("前奏の動きを確認できなかった: \(error)")
                return
            }
            guard let resume = self.firstHittableElement(in: self.app.buttons.matching(identifier: "Play"), timeout: 10)
            else {
                XCTFail("シーク後の再生ボタンが見つからなかった")
                return
            }
            resume.tap()
            for index in 0..<8 {
                guard intro.exists else { break }
                self.capture("prelude-playback-\(index)")
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
            }
            let firstLine = self.app.buttons.matching(
                NSPredicate(format: "label == %@", "瞳映る 静かな世界 なにを見てたんだろう")
            ).firstMatch
            let startsSinging = self.expectation(
                for: NSPredicate(format: "isSelected == true"), evaluatedWith: firstLine)
            XCTAssertEqual(XCTWaiter.wait(for: [startsSinging], timeout: 60), .completed)
            self.capture("prelude-first-line")
            guard let pause = self.firstHittableElement(in: self.app.buttons.matching(identifier: "Pause"), timeout: 10)
            else {
                XCTFail("歌い出し後の一時停止ボタンが見つからなかった")
                return
            }
            pause.tap()
        }
        XCTAssertTrue(skippedScreens.isEmpty)
    }
}
