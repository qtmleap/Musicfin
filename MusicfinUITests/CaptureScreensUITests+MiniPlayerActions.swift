import Foundation
import UIKit
import XCTest

extension CaptureScreensUITests {
    /// iPad のミニプレイヤー右端 3 つが「次へ」に化けず、それぞれ意図した動作になることを実測で確かめる。
    @MainActor
    func testPadMiniPlayerRightControls() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp(checksReferenceSize: false)
        ensureSignedIn()
        if ProcessInfo.processInfo.environment["MUSICFIN_REGRESSION_PORTRAIT"] == "1" {
            XCUIDevice.shared.orientation = .portrait
            settle()
        }
        let window = app.windows.firstMatch

        // 要素の `tap()` ではなく中心座標で押し、実際の当たり判定を通す。
        func tapCenter(_ element: XCUIElement) {
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(
                    CGVector(dx: element.frame.midX - window.frame.minX, dy: element.frame.midY - window.frame.minY)
                ).tap()
        }
        // 選択状態は tap 後の反映が遅れるため述語で待つ。タップが外れた場合は待ち切ってから失敗するので、見逃しは隠れない。
        func waitForSelected(_ element: XCUIElement, _ selected: Bool, timeout: TimeInterval = 5) -> Bool {
            let predicate = expectation(
                for: NSPredicate(format: "isSelected == %@", NSNumber(value: selected)), evaluatedWith: element)
            return XCTWaiter.wait(for: [predicate], timeout: timeout) == .completed
        }
        func note(_ name: String, _ element: XCUIElement) {
            print("[MiniPlayer] \(name) frame=\(element.frame)")
        }

        let album = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@", "home.top-pick.",
                "home.top-pick.favorites")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 30))
        album.tap()
        let shuffle = app.buttons["album.shuffle"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 30))
        shuffle.tap()

        let more = app.buttons["miniplayer.more"]
        let lyrics = app.buttons["miniplayer.lyrics"]
        let queue = app.buttons["miniplayer.queue"]
        let next = app.buttons["miniplayer.next"]
        let track = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
        for element in [more, lyrics, queue, next, track] {
            XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element.identifier) がない")
        }
        settle()
        for (name, element) in [("more", more), ("lyrics", lyrics), ("queue", queue), ("next", next)] {
            note(name, element)
        }
        // 右の 3 つは 40×44 を保ち、互いに重ならない。
        for element in [more, lyrics, queue] {
            XCTAssertEqual(element.frame.width, 40, accuracy: 1, "\(element.identifier) の幅")
            XCTAssertEqual(element.frame.height, 44, accuracy: 1, "\(element.identifier) の高さ")
        }
        XCTAssertLessThanOrEqual(more.frame.maxX, lyrics.frame.minX + 1)
        XCTAssertLessThanOrEqual(lyrics.frame.maxX, queue.frame.minX + 1)
        XCTAssertLessThanOrEqual(next.frame.maxX, track.frame.minX + 1, "次へが曲名の領域へ食い込んでいる")

        let initialLabel = track.label
        let miniShuffle = app.buttons["miniplayer.shuffle"]
        XCTAssertTrue(miniShuffle.waitForExistence(timeout: 10))
        XCTAssertTrue(miniShuffle.isSelected, "シャッフル開始がミニプレイヤーへ反映されていない")
        attachCapture("mini-player-shuffle-on")
        tapCenter(miniShuffle)
        XCTAssertTrue(waitForSelected(miniShuffle, false), "シャッフルを解除しても選択表示が残る")
        XCTAssertEqual(track.label, initialLabel, "シャッフル切替で現在曲が替わった")
        attachCapture("mini-player-shuffle-off")
        tapCenter(miniShuffle)
        XCTAssertTrue(waitForSelected(miniShuffle, true))
        XCTAssertEqual(track.label, initialLabel)
        let title = app.staticTexts["nowplaying.title"]

        // 「…」はメニューを開くだけで、曲も変えず、プレイヤーも開かない。
        tapCenter(more)
        let playNext = app.buttons.matching(
            NSPredicate(format: "label == 'Play Next' AND identifier != 'miniplayer.queue'")
        ).firstMatch
        let append = app.buttons["Add to Queue"]
        let favorite = app.buttons.matching(
            NSPredicate(format: "label == 'Add to Favorites' OR label == 'Remove from Favorites'")
        ).firstMatch
        XCTAssertTrue(append.waitForExistence(timeout: 10), "メニューに「最後に追加」がない")
        XCTAssertTrue(playNext.exists, "メニューに「次に再生」がない")
        XCTAssertTrue(favorite.exists, "メニューにお気に入りの操作がない")
        XCTAssertFalse(title.exists, "「…」でフルプレイヤーが開いた")
        attachCapture("mini-player-menu")
        // メニュー外の空き領域を押して、項目を選ばずに閉じる。
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(append.waitForNonExistence(timeout: 10), "メニューが閉じなかった")
        settle()
        XCTAssertEqual(track.label, initialLabel, "「…」で曲が替わった")

        func closeFullPlayer(from normalized: CGVector) {
            let from = app.coordinate(withNormalizedOffset: normalized)
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: normalized.dx, dy: 0.7))
            from.press(forDuration: 0.1, thenDragTo: to)
            XCTAssertTrue(title.waitForNonExistence(timeout: 10), "下スワイプでプレイヤーが閉じなかった")
            settle()
        }

        // 歌詞・キューは最初の 1 タップで目的の表示で開き、曲は替わらない（= 次へではない）。
        for (name, button) in [("lyrics", lyrics), ("queue", queue)] {
            tapCenter(button)
            XCTAssertTrue(title.waitForExistence(timeout: 10), "\(name): 1 回目のタップで開かなかった")
            let selected = app.buttons["nowplaying.mode.\(name)"]
            XCTAssertTrue(selected.waitForExistence(timeout: 10))
            XCTAssertTrue(selected.isSelected, "\(name): 選択状態になっていない")
            note("full-\(name)", selected)
            attachCapture("mini-player-open-\(name)")
            // 狭い幅の歌詞・キューは上端の帯だけが閉じる領域。広い幅は再生列（左）から閉じる。
            let size = window.frame.size
            let isWide = size.width >= 900
            closeFullPlayer(from: CGVector(dx: isWide ? 0.1 : 0.5, dy: isWide ? 0.5 : 40 / size.height))
            XCTAssertEqual(track.label, initialLabel, "\(name): 曲が替わった（次へが動いた）")
        }

        // 通常の入口は、直前が歌詞・キューでもアートワークで開く。
        tapCenter(track)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["nowplaying.mode.lyrics"].isSelected)
        XCTAssertFalse(app.buttons["nowplaying.mode.queue"].isSelected)
        let isWide = window.frame.width >= 900
        if !isWide { tapCenter(app.buttons["nowplaying.mode.queue"]) }
        let fullShuffle = app.buttons[isWide ? "nowplaying.shuffle" : "queue.mode.shuffle"]
        XCTAssertTrue(fullShuffle.waitForExistence(timeout: 10))
        XCTAssertTrue(fullShuffle.isSelected, "フルプレイヤーのシャッフル状態が一致しない")
        tapCenter(fullShuffle)
        XCTAssertTrue(waitForSelected(fullShuffle, false))
        attachCapture(isWide ? "mini-player-open-artwork" : "mini-player-queue-shuffle-off")
        closeFullPlayer(from: CGVector(dx: 0.5, dy: isWide ? 0.3 : 40 / window.frame.height))
        XCTAssertEqual(track.label, initialLabel)
        XCTAssertTrue(waitForSelected(miniShuffle, false), "フルプレイヤーでの解除がミニプレイヤーへ反映されない")
        app.buttons["album.shuffle"].tap()
        XCTAssertTrue(waitForSelected(miniShuffle, true))
        app.buttons["album.play"].tap()
        XCTAssertTrue(waitForSelected(miniShuffle, false), "通常再生でシャッフル表示が解除されない")
    }

    @MainActor
    private func attachCapture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
