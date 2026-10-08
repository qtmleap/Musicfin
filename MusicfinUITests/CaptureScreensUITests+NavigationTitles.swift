import Foundation
import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testTabNavigationTitlesUseSystemLayout() throws {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()
        // iPad の通常幅にはタブバーが無いため、sidebar は既存の root テストで確認する。
        try XCTSkipIf(app.tabBars.count == 0, "4 タブの比較はタブバーを使う端末が対象")
        var expectedTitle: CGRect?

        for destination in [("Home", "home"), ("New", "new"), ("Radio", "radio"), ("Library", "library")] {
            selectNavigationTitleTab(destination.0)
            let title = app.navigationBars.staticTexts[destination.0].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            let initialTitle = title.frame
            XCTAssertGreaterThan(initialTitle.height, 30)
            let expectedIconCount = destination.1 == "new" ? 2 : destination.1 == "radio" ? 0 : 1
            let icons = app.navigationBars.buttons.allElementsBoundByIndex
            // Menu は同じ操作を二重の要素として返すため、画面上の操作位置で余計なボタンを検出する。
            let iconPositions = Set(icons.map { "\(Int($0.frame.midX.rounded())):\(Int($0.frame.midY.rounded()))" })
            XCTAssertEqual(
                iconPositions.count, expectedIconCount,
                "空のタイトルが余計な操作を追加していた")
            if destination.1 != "radio" {
                let icon = app.navigationBars.buttons.firstMatch
                XCTAssertTrue(icon.isHittable)
                XCTAssertEqual(initialTitle.midY, icon.frame.midY, accuracy: 3, "タイトルと右上のアイコンが別の行にあった")
            }
            if let expectedTitle {
                XCTAssertEqual(initialTitle.minY, expectedTitle.minY, accuracy: 1)
                XCTAssertEqual(initialTitle.height, expectedTitle.height, accuracy: 1)
                XCTAssertEqual(initialTitle.minX, expectedTitle.minX, accuracy: 1)
            } else {
                expectedTitle = initialTitle
            }
            if destination.1 == "radio" {
                let track = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "radio.track."))
                    .firstMatch
                XCTAssertTrue(track.waitForExistence(timeout: 30))
                XCTAssertLessThan(track.frame.minY - initialTitle.maxY, 36, "Radio の上部に余計な隙間があった")
            }
            XCTAssertFalse(app.searchFields.firstMatch.isHittable, "検索欄がタブの入口を押し下げていた")
            attachNavigationTitleScreenshot("\(destination.1)-native-top")
            assertNavigationTitleIsDrawn(in: initialTitle)

            for _ in 0..<2 { app.swipeUp() }
            attachNavigationTitleScreenshot("\(destination.1)-native-scrolled")
            // システムによる退場を確認し、バーを丸ごと画面外へ動かす実装を見逃さない。
            XCTAssertTrue(app.navigationBars.firstMatch.exists)
            assertNavigationTitleRetired(title)
            for _ in 0..<4 { app.swipeDown() }
            XCTAssertTrue(title.isHittable)
            XCTAssertEqual(title.frame.height, initialTitle.height, accuracy: 1)
        }
    }

    @MainActor
    func testLibraryRecentlyAddedHeadingScrollsWithAlbums() {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()
        selectNavigationTitleTab("Library")

        let heading = app.staticTexts["Recently Added"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 30))
        XCTAssertTrue(heading.isHittable)
        attachNavigationTitleScreenshot("library-recently-added-top")

        for _ in 0..<2 { app.swipeUp() }
        attachNavigationTitleScreenshot("library-recently-added-scrolled")
        let retired = NSPredicate { _, _ in !heading.exists || !heading.isHittable }
        XCTAssertTrue(
            XCTWaiter.wait(for: [expectation(for: retired, evaluatedWith: nil)], timeout: 5) == .completed,
            "Recently Added の見出しが画面上部に固定されていた")

        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(heading.isHittable)
    }

    @MainActor
    func testTabRootNavigationTitles() {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()

        let usesSidebar = app.tabBars.count == 0
        let destinations: [(title: String, route: String)] =
            usesSidebar
            ? [("Home", "home"), ("New", "new"), ("Radio", "radio"), ("Search", "search")]
            : [("Home", "home"), ("New", "new"), ("Radio", "radio"), ("Library", "library"), ("Search", "search")]

        for destination in destinations {
            if usesSidebar {
                let row = padSidebarRow("sidebar.\(destination.route)")
                XCTAssertTrue(row.waitForExistence(timeout: 10))
                row.tap()
            } else {
                selectNavigationTitleTab(destination.title)
            }

            let title = app.navigationBars.staticTexts[destination.title].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 10), "\(destination.title) の標準タイトルが表示されなかった")
            let before = title.frame
            XCTAssertGreaterThan(before.height, 30)
            if destination.route == "new" {
                XCTAssertFalse(app.descendants(matching: .any)["library.albums.actions"].exists)
                let playbackActions = app.navigationBars.buttons.matching(
                    NSPredicate(format: "label IN %@", ["Play", "Shuffle", "再生", "シャッフル"]))
                XCTAssertEqual(playbackActions.count, 0, "New に一括再生の操作が残っていた")
                attachNavigationTitleScreenshot("new-without-playback-actions")
            }
            if !usesSidebar, destination.route == "search" {
                assertNavigationTitleIsDrawn(in: before)
            }
            if ["home", "new", "library"].contains(destination.route) {
                if !usesSidebar {
                    let icon = app.navigationBars.buttons.firstMatch
                    XCTAssertTrue(icon.isHittable)
                    XCTAssertEqual(before.midY, icon.frame.midY, accuracy: 3, "タイトルとアイコンが別の行にあった")
                }
                for _ in 0..<2 { app.swipeUp() }
                assertNavigationTitleRetired(title)
                if destination.route == "new" {
                    let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.card."))
                    let visibleCard = cards.allElementsBoundByIndex.first { $0.isHittable }
                    XCTAssertNotNil(visibleCard)
                    visibleCard?.tap()
                    let back = app.navigationBars.buttons.firstMatch
                    XCTAssertTrue(back.waitForExistence(timeout: 10))
                    XCTAssertTrue(back.isHittable)
                    app.swipeUp()
                    XCTAssertTrue(back.isHittable)
                    back.tap()
                }
                for _ in 0..<4 { app.swipeDown() }
                XCTAssertTrue(title.isHittable)
                XCTAssertEqual(title.frame.height, before.height, accuracy: 1)
            }

            if destination.route == "home" || destination.route == "library" {
                let account = app.navigationBars.buttons["Account"].firstMatch
                XCTAssertTrue(account.isHittable)
                account.tap()
                XCTAssertTrue(app.staticTexts["Jellyfin Account"].waitForExistence(timeout: 10))
                element(.button, "閉じる").tap()
                XCTAssertTrue(account.waitForExistence(timeout: 10))
                app.swipeUp()
                assertNavigationTitleRetired(title)
                for _ in 0..<2 { app.swipeDown() }
                XCTAssertTrue(title.isHittable)
            }

            if !usesSidebar, destination.route == "library" {
                let songs = app.buttons["library.songs"]
                XCTAssertTrue(songs.isHittable)
                songs.tap()
                let songTitle = app.navigationBars.staticTexts["Songs"].firstMatch
                XCTAssertTrue(songTitle.waitForExistence(timeout: 10))
                let song = app.descendants(matching: .any)["song.row"].firstMatch
                XCTAssertTrue(song.waitForExistence(timeout: 30))
                for _ in 0..<2 { app.swipeUp() }
                // 入口の空タイトルを詳細へ持ち越すと、詳細の小さい標準タイトルまで消えてしまう。
                XCTAssertTrue(songTitle.isHittable)
                let back = app.navigationBars.buttons.firstMatch
                XCTAssertTrue(back.isHittable)
                back.tap()
            }
        }
    }

    @MainActor
    private func assertNavigationTitleIsDrawn(in frame: CGRect) {
        // アクセシビリティの矩形が残っていても、固定領域に覆われたタイトルは画像に描かれない。
        let screenshot = app.screenshot().image
        guard let source = screenshot.cgImage else {
            XCTFail("タイトルの描画を確認する画像が無かった")
            return
        }
        let scale = CGFloat(source.width) / app.frame.width
        let rect = CGRect(
            x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        guard let crop = source.cropping(to: rect.integral) else {
            XCTFail("タイトルの矩形が画像外にあった")
            return
        }
        let width = crop.width
        let height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let count = pixels.withUnsafeMutableBytes { bytes -> Int in
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return 0 }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            let values = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: values.count, by: 4).filter {
                values[$0] > 180 && values[$0 + 1] > 180 && values[$0 + 2] > 180
            }.count
        }
        XCTAssertGreaterThan(count, 20, "標準タイトルが他の領域に覆われて描画されていなかった")
    }

    @MainActor
    private func assertNavigationTitleRetired(_ title: XCUIElement) {
        // 小さいタイトルへの切り替えでは要件を満たさないため、退場そのものを確認する。
        let retired = NSPredicate { _, _ in
            !title.exists || !title.isHittable
        }
        XCTAssertTrue(
            XCTWaiter.wait(for: [expectation(for: retired, evaluatedWith: nil)], timeout: 5) == .completed,
            "スクロール後もタイトルが表示されていた")
    }

    @MainActor
    private func selectNavigationTitleTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        if !tab.exists {
            // 先頭で引き下げても offset は変わらないため、縮んだタブバーは選択中の丸薬を押して戻す。
            let compact = app.buttons.allElementsBoundByIndex.first {
                ["Home", "New", "Radio", "Library"].contains($0.label)
                    && $0.isHittable && $0.frame.minY > app.frame.height * 0.75
            }
            compact?.tap()
        }
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    @MainActor
    private func attachNavigationTitleScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
