import XCTest

final class TelemetryPrivacyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testPrivacyBeforeConnecting() {
        let japanese = ProcessInfo.processInfo.environment["MUSICFIN_PRIVACY_LANGUAGE"] == "ja"
        let language = japanese ? "ja" : "en"
        let eligible = ProcessInfo.processInfo.environment["MUSICFIN_PRIVACY_EXPECT_ELIGIBLE"] == "1"
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch()

        let privacy = app.buttons["privacy-settings-button"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 15))
        reveal(privacy, in: app)
        XCTAssertTrue(privacy.isHittable)
        privacy.tap()

        let sharing = app.switches["telemetry-sharing-toggle"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 10))
        XCTAssertEqual(sharing.value as? String, "0")
        // 開発ビルドの保存済み設定を理由に送信を許可しない。
        XCTAssertEqual(sharing.isEnabled, eligible)
        XCTAssertEqual(sharing.label, japanese ? "利用状況と不具合情報を共有" : "Share Usage and Crash Data")
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    japanese ? "使いやすさと安定性の改善" : "To improve usability and stability")
            ).firstMatch.exists
        )
        let policy = app.descendants(matching: .any).matching(identifier: "privacy-policy-link").firstMatch
        reveal(policy, in: app)
        XCTAssertTrue(policy.isHittable)
        XCTAssertEqual(policy.label, japanese ? "プライバシーポリシー" : "Privacy Policy")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "privacy-before-login-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let close = app.buttons[japanese ? "閉じる" : "Close"]
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        app.terminate()
        if !eligible {
            app.launchArguments += ["-MusicfinTelemetryChoice.v1", "YES"]
        }
        app.launch()
        reveal(privacy, in: app)
        privacy.tap()
        XCTAssertTrue(sharing.waitForExistence(timeout: 5))
        XCTAssertEqual(sharing.value as? String, "0")
        app.terminate()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable {
            app.swipeUp()
        }
    }
}
