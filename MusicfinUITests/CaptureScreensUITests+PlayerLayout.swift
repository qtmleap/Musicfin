import Foundation
import XCTest

extension CaptureScreensUITests {
    /// 文字の帯だけを拡大すると、絶対位置の画像へ曲名が重なる。外側を送れるだけでは解消しない。
    @MainActor
    func testPadLargeTextKeepsArtworkAboveTitle() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp()
        ensureSignedIn()
        app.terminate()
        app.launchEnvironment["MUSICFIN_CAPTURE_PLAYER"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        let queue = element(.button, "次に再生")
        XCTAssertTrue(queue.waitForExistence(timeout: 15), "フルプレイヤーが表示されなかった")
        queue.tap()
        settle()
        let artwork = element(.button, "アートワークへ戻る")
        let title = app.staticTexts["nowplaying.title"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 10), "アートワークが表示されなかった")
        XCTAssertLessThan(artwork.frame.maxY, title.frame.minY, "拡大した曲名がアートワークへ重なった")
        XCTAssertTrue(queue.isHittable, "文字拡大でキューから戻れなくなった")
    }

    /// iPhone 用の縦積みが横長の窓まで広がると、キューと操作が同じ列を奪い合う。
    /// 再生データに依存しない空のキューで、表示位置と切り替え後の操作可能性を確かめる。
    @MainActor
    func testPadPlayerKeepsControlsBesideQueue() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp()
        ensureSignedIn()
        app.terminate()
        launchApp(capturePlayer: true)

        let title = app.staticTexts["nowplaying.title"]
        let queue = element(.button, "次に再生")
        XCTAssertTrue(queue.waitForExistence(timeout: 15), "フルプレイヤーが表示されなかった")
        let seek = app.otherElements.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
        ).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10), "シークバーが表示されなかった")
        settle()

        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(seek.frame.width, window.width / 2, "再生操作が窓全体へ引き伸ばされている")
        XCTAssertEqual(seek.frame.midX, window.midX, accuracy: 8, "通常表示の再生操作が中央にない")
        let controlsY = seek.frame.midY

        queue.tap()
        settle()
        let heading = app.staticTexts["Play Next"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "キューの見出しが表示されなかった")
        XCTAssertLessThan(title.frame.maxX, window.midX, "曲情報が左カラムに収まっていない")
        XCTAssertLessThan(seek.frame.maxX, window.midX, "再生操作が左カラムに収まっていない")
        XCTAssertGreaterThan(heading.frame.minX, window.width * 0.45, "キューが右カラムに配置されていない")
        XCTAssertGreaterThan(heading.frame.minX, seek.frame.maxX, "キューと再生操作が横に分離していない")
        XCTAssertEqual(seek.frame.midY, controlsY, accuracy: 8, "キューへの切り替えで再生操作が上下に移動した")
        XCTAssertTrue(queue.isHittable, "キューから戻る操作が隠れた")
        XCTAssertTrue(element(.button, "歌詞").isHittable, "歌詞への切り替え操作が隠れた")

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "ipad-player-queue-layout"
        attachment.lifetime = .keepAlways
        add(attachment)

        queue.tap()
        settle()
        XCTAssertFalse(heading.exists, "通常表示へ戻ってもキューが残った")
        XCTAssertEqual(seek.frame.midX, window.midX, accuracy: 8, "通常表示へ戻っても操作が左に残った")

        // 全画面 cover は sheet の終了操作を持たないため、見た目だけのグラバーに戻る退行を防ぐ。
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        origin.press(forDuration: 0.1, thenDragTo: destination)
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "上端を下へ引いてもプレイヤーが閉じなかった")
        XCTAssertTrue(app.buttons["sidebar.account"].isHittable, "閉じた後にライブラリへ操作が戻らなかった")
    }
}
