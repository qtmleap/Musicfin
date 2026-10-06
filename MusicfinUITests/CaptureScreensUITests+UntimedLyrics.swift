import Foundation
import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testUntimedLyricsManualScrollKeepsControlsStable() {
        openLyrics(
            query: "SCRE4M NOiSE M4KER", albumID: "9b3230a42a0d86f02e0af1902c9a385c",
            trackID: "0777b56919f14cfaec35d3912815b8f9", title: "! SCRE4M NOiSE M4KER")
        let lyrics = element(.button, "歌詞")
        let notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "have no timing information"))
            .firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "時刻のない実歌詞を取得できなかった")
        assertManualControlsStayStable(lyrics: lyrics)
    }

    @MainActor
    func testTimedLyricsManualScrollKeepsControlsStable() {
        openLyrics(
            query: "超かぐや姫!", albumID: Self.cosmicAlbumID,
            trackID: Self.replyItemID, title: "Reply")
        let first = app.buttons["瞳映る 静かな世界 なにを見てたんだろう"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.tap()
        assertManualControlsStayStable(lyrics: element(.button, "歌詞"))
    }

    @MainActor
    func testTimedLyricsManualReadWaitsForVisibleCurrentLine() {
        openLyrics(
            query: "超かぐや姫!", albumID: Self.cosmicAlbumID,
            trackID: Self.replyItemID, title: "Reply")
        let first = app.buttons["瞳映る 静かな世界 なにを見てたんだろう"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.tap()
        XCTAssertTrue(first.isSelected)
        settle()
        let alignedY = first.frame.midY
        for _ in 0..<3 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertFalse(first.isHittable, "現在行を画面外へ読み進められなかった")
        // 旧3秒タイマーが読み返している位置を奪っていたため、待った後も現在行が外にあることを確かめる。
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 5))
        XCTAssertFalse(first.isHittable, "画面外の現在行へ勝手にスクロールした")
        for _ in 0..<8 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(
                forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 250)),
                withVelocity: .slow, thenHoldForDuration: 0)
            if first.isHittable { break }
        }
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable, "現在行へ戻れなかった")
        XCTAssertTrue(first.isSelected, "手動スクロールで現在行の選択が失われた")
        settle()
        XCTAssertEqual(first.frame.midY, alignedY, accuracy: 3, "可視になった現在行へ追従を取り直さなかった")
    }

    @MainActor
    private func openLyrics(query: String, albumID: String, trackID: String, title: String) {
        launchApp()
        ensureSignedIn()
        selectTab("検索")
        let search = searchFieldElement
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(typeSearchQuery(search, query))
        dismissKeyboard()
        let album = app.buttons["search.result.MusicAlbum.\(albumID)"]
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
        let track = app.buttons["album.track.\(trackID)"]
        for _ in 0..<6 {
            if track.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(track.waitForExistence(timeout: 20))
        settle()
        track.tap()
        let openPlayer = app.buttons["\(title), Open Player"]
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 20))
        settle()
        openPlayer.tap()
        let lyrics = element(.button, "歌詞")
        XCTAssertTrue(lyrics.waitForExistence(timeout: 10))
        if let pause = firstHittableElement(in: app.buttons.matching(identifier: "Pause"), timeout: 5) { pause.tap() }
        lyrics.tap()
    }

    @MainActor
    private func assertManualControlsStayStable(lyrics: XCUIElement) {
        settle()

        // 帯が動く間も一方向へ送り続け、器の補正が反対向きの操作として入り込まないことを確かめる。
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(
            forDuration: 0.1, thenDragTo: end, withVelocity: XCUIGestureVelocity(rawValue: 100),
            thenHoldForDuration: 0.8)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        XCTAssertFalse(lyrics.exists, "読み進めた後に操作帯が勝手に戻った")
        for _ in 0..<6 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            XCTAssertFalse(lyrics.exists, "操作帯が静止中に振動した")
        }

        let reverseStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        // 帯の復帰中に位置が押し戻されると、指が動き続けても本文だけが途中で止まる。
        let candidate = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "lyrics.line.")
        ).allElementsBoundByIndex.first {
            $0.frame.minY > app.frame.height * 0.26
                && $0.frame.maxY < app.frame.height * 0.57 && $0.isHittable
        }
        guard let candidate else {
            XCTFail("移動量を確かめる表示中の歌詞が見つからなかった")
            return
        }
        let readingLine = app.descendants(matching: .any).matching(identifier: candidate.identifier).firstMatch
        let readingY = readingLine.frame.minY
        reverseStart.press(
            forDuration: 0.1, thenDragTo: reverseStart.withOffset(CGVector(dx: 0, dy: 50)),
            withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertGreaterThanOrEqual(
            readingLine.frame.minY - readingY, 35, "コントロールの復帰中に歌詞が指の移動へ追従しなくなった")
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5), "読み戻しても操作帯が戻らなかった")
        for _ in 0..<6 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            XCTAssertTrue(lyrics.exists, "読み戻した後に操作帯が勝手に隠れた")
        }
    }
}
