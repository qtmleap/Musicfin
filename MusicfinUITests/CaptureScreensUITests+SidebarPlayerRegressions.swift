import Foundation
import UIKit
import XCTest

extension CaptureScreensUITests {
    /// アカウント sheet の表示・終了で板の幅や位置が動いた退行を、frame の実測で捕まえる。
    @MainActor
    func testPadAccountKeepsSidebarWidth() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp(checksReferenceSize: false)
        ensureSignedIn()
        let coldAccount = app.buttons["sidebar.account"]
        XCTAssertTrue(coldAccount.waitForExistence(timeout: 20))
        settle()
        print(
            "[SidebarWidth] cold account=\(coldAccount.frame) detailTitle=\(app.navigationBars["Home"].staticTexts["Home"].firstMatch.frame)"
        )
        XCTAssertEqual(coldAccount.frame.width, 269.5, accuracy: 1)
        XCTAssertEqual(
            app.navigationBars["Home"].staticTexts["Home"].firstMatch.frame.minX, 299.5, accuracy: 2,
            "固定した板だけ合っていても、実際の detail 列が 320 pt へ戻っていてはならない")
        // ログイン済みで起動する日常の経路も通し、初回ログインだけ正しくなる修正を防ぐ。
        app.terminate()
        launchApp(checksReferenceSize: false)
        prepareRegressionOrientation()
        let account = app.buttons["sidebar.account"]
        let home = padSidebarRow("sidebar.home")
        XCTAssertTrue(account.waitForExistence(timeout: 20))
        XCTAssertTrue(home.waitForExistence(timeout: 20))
        settle()
        let accountBefore = account.frame
        let homeBefore = home.frame
        print(
            "[SidebarWidth] before account=\(accountBefore) home=\(homeBefore) detailTitle=\(app.navigationBars["Home"].staticTexts["Home"].firstMatch.frame)"
        )
        XCTAssertEqual(accountBefore.width, 269.5, accuracy: 1)
        XCTAssertEqual(app.navigationBars["Home"].staticTexts["Home"].firstMatch.frame.minX, 299.5, accuracy: 2)
        attachScreenshot("sidebar-account-before")

        func assertStable(_ phase: String) {
            guard account.exists, home.exists else {
                XCTFail("\(phase): シート背後のメニューを測定できなかった")
                return
            }
            print("[SidebarWidth] \(phase) account=\(account.frame) home=\(home.frame)")
            XCTAssertEqual(account.frame.width, accountBefore.width, accuracy: 1, "\(phase): account 行の幅が変わった")
            XCTAssertEqual(account.frame.minX, accountBefore.minX, accuracy: 1, "\(phase): account 行の左端が動いた")
            XCTAssertEqual(home.frame.width, homeBefore.width, accuracy: 1, "\(phase): Home 行の幅が変わった")
            XCTAssertEqual(home.frame.minX, homeBefore.minX, accuracy: 1, "\(phase): Home 行の左端が動いた")
        }

        // 板の行ではなく Home のツールバーのボタンから開いた場合も、板の幅が動かないことを見る。
        let usesToolbar = ProcessInfo.processInfo.environment["MUSICFIN_REGRESSION_ACCOUNT_TOOLBAR"] == "1"

        for round in 1...2 {
            if usesToolbar {
                let toolbarAccount = app.navigationBars.buttons["Account"].firstMatch
                XCTAssertTrue(toolbarAccount.waitForExistence(timeout: 10), "\(round) 回目: Home のアカウントボタンがない")
                toolbarAccount.tap()
            } else {
                // 中心座標で押し、行の空白部分でも sheet が開くことまで確かめる。
                app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: account.frame.midX, dy: account.frame.midY)).tap()
            }
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10), "\(round) 回目: アカウント sheet が開かなかった")
            assertStable("\(round) 回目の提示中")
            settle()
            attachScreenshot("sidebar-account-open-\(round)")
            assertStable("\(round) 回目の表示後")

            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 10), "\(round) 回目: アカウント sheet が閉じなかった")
            settle()
            attachScreenshot("sidebar-account-after-\(round)")
            assertStable("\(round) 回目の終了後")
        }
    }

    /// シャッフル再生中にミニプレイヤーから開いても再生が再開せず、位置も保たれることを確かめる。
    @MainActor
    func testPadShuffledMiniPlayerControls() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp(checksReferenceSize: false)
        ensureSignedIn()
        prepareRegressionOrientation()
        let window = app.windows.firstMatch
        func tapCenter(_ element: XCUIElement) {
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(
                    CGVector(dx: element.frame.midX - window.frame.minX, dy: element.frame.midY - window.frame.minY)
                ).tap()
        }
        func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 10) -> Bool {
            let predicate = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
            return XCTWaiter.wait(for: [predicate], timeout: timeout) == .completed
        }

        if ProcessInfo.processInfo.environment["MUSICFIN_REGRESSION_PLAYLIST"] == "1" {
            // ピン留めは "sidebar.pin." なので、"sidebar.playlist." だけを見れば重複や favorites を踏まない。
            let row = app.descendants(matching: .staticText).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.playlist.")
            ).firstMatch
            for _ in 0..<6 {
                if row.exists && row.isHittable { break }
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8))
                    .press(
                        forDuration: 0.05,
                        thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)))
                settle()
            }
            XCTAssertTrue(row.isHittable, "サイドバーにプレイリストがない")
            row.tap()
            settle()
            XCTAssertTrue(app.staticTexts["playlist.detail"].waitForExistence(timeout: 20))
        } else {
            let album = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND identifier != %@", "home.top-pick.",
                    "home.top-pick.favorites")
            ).firstMatch
            XCTAssertTrue(album.waitForExistence(timeout: 30))
            album.tap()
        }
        let shuffle = app.buttons["album.shuffle"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 30))
        shuffle.tap()

        let miniPause = app.buttons["miniplayer.play-pause"]
        XCTAssertTrue(miniPause.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(miniPause, "Pause"), "シャッフル後に再生が始まらなかった")
        if ProcessInfo.processInfo.environment["MUSICFIN_REGRESSION_DEMO_VIDEO"] == "1" {
            settle()
            for round in 1...3 {
                let account = app.buttons["sidebar.account"]
                XCTAssertTrue(account.waitForExistence(timeout: 10))
                attachScreenshot("demo-before-\(round)")
                tapCenter(account)
                let close = app.buttons["Close"]
                XCTAssertTrue(close.waitForExistence(timeout: 10))
                settle()
                attachScreenshot("demo-open-\(round)")
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
                close.tap()
                XCTAssertTrue(close.waitForNonExistence(timeout: 10))
                settle()
            }
        }
        tapCenter(miniPause)
        XCTAssertTrue(waitForLabel(miniPause, "Play"), "ミニプレイヤーで一時停止できなかった")

        // 詳細の「曲名、Open Player」は全画面プレイヤーを開く唯一の入口。
        let openPlayer = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 20))
        let firstOpenLabel = openPlayer.label
        tapCenter(openPlayer)
        let title = app.staticTexts["nowplaying.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let fullPause = app.buttons["nowplaying.play-pause"]
        XCTAssertTrue(fullPause.waitForExistence(timeout: 10))
        // 開いた直後だけでなく少し待った後も止まったままか（開く操作が再生を再開しない）。
        settle()
        XCTAssertEqual(fullPause.label, "Play", "プレイヤーを開くと一時停止が解除された")
        attachScreenshot("mini-player-open-paused")

        // 再生位置: シークで 30 秒以上へ進め、閉じて開き直しても同じ位置か確かめる。
        let seek = app.otherElements.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
        ).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10))
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: seek.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        settle()
        let sought = playbackSeconds(of: seek)
        XCTAssertNotNil(sought)
        XCTAssertGreaterThanOrEqual(sought ?? 0, 30, "シークで 30 秒以上へ進められなかった")
        XCTAssertEqual(fullPause.label, "Play", "シークで再生が再開した")

        func closeFullPlayer() {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            from.press(forDuration: 0.1, thenDragTo: to)
            XCTAssertTrue(title.waitForNonExistence(timeout: 10), "下スワイプでプレイヤーが閉じなかった")
            settle()
        }
        closeFullPlayer()
        XCTAssertEqual(miniPause.label, "Play")

        let miniTrack = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
        XCTAssertTrue(miniTrack.waitForExistence(timeout: 10))
        let firstLabel = miniTrack.label
        XCTAssertEqual(firstLabel, firstOpenLabel)
        tapCenter(miniTrack)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(seek.waitForExistence(timeout: 10))
        settle()
        XCTAssertEqual(fullPause.label, "Play", "ミニプレイヤーから開くと再生が再開した")
        XCTAssertEqual(
            Double(playbackSeconds(of: seek) ?? -1), Double(sought ?? -2), accuracy: 2,
            "開き直しで再生位置が変わった")
        closeFullPlayer()

        // 次の曲: 全画面は閉じてあるので、"Next Track" は帯の 1 つだけが対象になる。
        XCTAssertFalse(title.exists)
        let next = app.buttons.matching(NSPredicate(format: "label == %@", "Next Track")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.isEnabled, "シャッフルのキューに次の曲がない（2 曲以上のアルバムが必要）")
        tapCenter(next)
        let changed = expectation(
            for: NSPredicate(format: "label ENDSWITH 'Open Player' AND label != %@", firstLabel),
            evaluatedWith: miniTrack)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed, "次の曲へ進まなかった")
        attachScreenshot("mini-player-after-next")

        // 次へ進んだ後でも一時停止・再開が働くこと。
        if miniPause.label == "Play" {
            tapCenter(miniPause)
            XCTAssertTrue(waitForLabel(miniPause, "Pause"), "次の曲で再生できなかった")
        }
        tapCenter(miniPause)
        XCTAssertTrue(waitForLabel(miniPause, "Play"), "次の曲で一時停止できなかった")
    }

    @MainActor
    private func prepareRegressionOrientation() {
        guard ProcessInfo.processInfo.environment["MUSICFIN_REGRESSION_PORTRAIT"] == "1" else { return }
        XCUIDevice.shared.orientation = .portrait
        let window = app.windows.firstMatch
        let deadline = Date(timeIntervalSinceNow: 15)
        while window.frame.height <= window.frame.width, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        XCTAssertGreaterThan(window.frame.height, window.frame.width)
        settle()
    }

    /// シークバーの value（m:ss）を秒へ戻す。
    @MainActor
    private func playbackSeconds(of seek: XCUIElement) -> Int? {
        guard let value = seek.value as? String else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
