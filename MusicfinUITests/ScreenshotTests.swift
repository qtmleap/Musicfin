import XCTest

/// UI の目視比較用にスクリーンショットを撮る。
///
/// 検証ではなく記録が目的なので、要素が見つからない場合もテストは失敗させず、
/// その画面を飛ばして次へ進む。実装ごとに画面構成が違っても、撮れるところまでは撮れる。
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    /// 撮影対象のサーバー。CI や別サーバーで撮るときは環境変数で差し替える。
    private var server: String {
        ProcessInfo.processInfo.environment["MUSICFIN_SERVER"] ?? "https://demo.jellyfin.org/stable"
    }

    private var user: String {
        ProcessInfo.processInfo.environment["MUSICFIN_USER"] ?? "demo"
    }

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = [
            "-MusicfinServer", server,
            "-MusicfinUser", user,
            "-MusicfinPassword", ProcessInfo.processInfo.environment["MUSICFIN_PASSWORD"] ?? "",
        ]
    }

    func testCaptureScreens() {
        app.launch()

        // 自動ログインとライブラリ取得の完了を待つ。タブバーの出現をもって準備完了とみなす。
        let libraryTab = app.buttons["ライブラリ"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 40), "ログインまたはライブラリ取得に失敗しました")
        settle()
        capture("01-home")

        // ライブラリタブ
        if tap(libraryTab) {
            settle()
            capture("02-library")
            // 5 分類のうち最初の行（アルバム）へ進む
            if tap(app.buttons["アルバム"].firstMatch) || tap(app.staticTexts["アルバム"].firstMatch) {
                settle()
                capture("03-library-albums")
            }
        }

        // アルバム詳細 → 再生
        goHome()
        if tapFirstAlbum() {
            settle()
            capture("04-album-detail")

            if tap(app.buttons["再生"].firstMatch) {
                settle(seconds: 3)
                capture("05-miniplayer")

                // ミニプレイヤーからフルプレイヤーを開く
                if tapMiniPlayer() {
                    settle(seconds: 2)
                    capture("06-nowplaying")

                    for (label, name) in [("歌詞", "07-lyrics"), ("次に再生", "08-queue")] {
                        if tap(app.buttons[label].firstMatch) {
                            settle()
                            capture(name)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 補助

    /// アニメーションと非同期の読み込みが落ち着くのを待つ。
    private func settle(seconds: TimeInterval = 2) {
        _ = app.wait(for: .runningForeground, timeout: 1)
        Thread.sleep(forTimeInterval: seconds)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5), element.isHittable else { return false }
        element.tap()
        return true
    }

    private func goHome() {
        _ = tap(app.buttons["ホーム"].firstMatch)
        settle(seconds: 1)
    }

    /// ホームの最初のアルバムカードを開く。カードの構造は実装によって違うので、
    /// ボタン → セル → 画像 の順に当たりを探す。
    private func tapFirstAlbum() -> Bool {
        for query in [app.buttons, app.cells, app.images] {
            let candidates = query.allElementsBoundByIndex.filter { $0.isHittable }
            // タブバーのボタンを避けるため、画面上部 3/4 にあるものだけを対象にする。
            if let target = candidates.first(where: { $0.frame.midY < app.frame.height * 0.75 }) {
                target.tap()
                return true
            }
        }
        return false
    }

    private func tapMiniPlayer() -> Bool {
        // ミニプレイヤーはタブバーのすぐ上にある。画面下端付近で最も広いものを選ぶ。
        let bottom = app.frame.height * 0.78
        let candidates = app.buttons.allElementsBoundByIndex
            .filter { $0.isHittable && $0.frame.midY > bottom }
            .sorted { $0.frame.width > $1.frame.width }
        guard let target = candidates.first else { return false }
        target.tap()
        return true
    }
}
