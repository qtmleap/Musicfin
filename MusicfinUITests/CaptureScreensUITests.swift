import XCTest

/// 主要画面を同じ手順で撮影し、`docs/screenshots/manifest.json`（スクリプトが生成）経由で比較できるようにする。
/// 保存先は `MUSICFIN_SHOT_DIR` で受け取る。
/// アプリ本体に `accessibilityIdentifier` を足さず、表示ラベルだけで操作する。
final class CaptureScreensUITests: XCTestCase {
    private static let demoServerURL = "https://demo.jellyfin.org/stable"
    private static let demoUser = "demo"

    // XCUIApplication は MainActor 隔離なので、テスト本体と補助メソッドを MainActor に置く。
    // クラス自体を MainActor にすると XCTestCase の nonisolated な override と衝突する。
    private var app: XCUIApplication!
    private var shotDirectory: URL?
    private var capturedNames: Set<String> = []
    private var skippedScreens: [String] = []

    override func setUpWithError() throws {
        // 1 つの画面が撮れなくても残りは撮り切りたい。
        continueAfterFailure = true

        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["MUSICFIN_SHOT_DIR"], !directory.isEmpty {
            shotDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        }
    }

    @MainActor
    private func launchApp() {
        app = XCUIApplication()
        app.launchEnvironment["MUSICFIN_SHOT_DIR"] = shotDirectory?.path ?? ""
        app.launch()
    }

    // MARK: - ログイン画面

    @MainActor
    func testCaptureLoginScreens() throws {
        launchApp()

        // 起動直後はセッション復元でホームかログイン画面のどちらかになる。
        let settings = app.buttons["設定"]
        let connect = app.buttons["接続"]
        XCTAssertTrue(
            waitForAny([settings, connect], timeout: 20),
            "起動後にホームもログイン画面も表示されなかった")

        if settings.exists {
            signOutFromHome()
        }

        XCTAssertTrue(connect.waitForExistence(timeout: 10), "ログイン画面（サーバー入力）が表示されなかった")
        capture("login-server")

        enterServerURL()
        connect.tap()

        let changeServer = app.buttons["サーバーを変更"]
        XCTAssertTrue(changeServer.waitForExistence(timeout: 20), "認証ステップが表示されなかった")
        dismissKeyboard()
        settle()
        capture("login-credentials")

        captureQuickConnect()
        signInWithPassword()

        // 手順 1 で撮れなかった場合の保険。ログイン済みの状態で終える。
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "ログイン後にホームが表示されなかった")
        if !capturedNames.contains("settings") {
            settings.tap()
            let close = app.buttons["閉じる"]
            XCTAssertTrue(close.waitForExistence(timeout: 10), "設定画面が表示されなかった")
            settle()
            capture("settings")
            close.tap()
        }
    }

    /// ホーム右上の「設定」から設定画面を撮り、確認ダイアログ経由でログアウトする。
    @MainActor
    private func signOutFromHome() {
        app.buttons["設定"].tap()
        // 「ログアウト」は画面下にあり iPhone では画面外（未生成）のことがあるので、表示の検出には「閉じる」を使う。
        guard app.buttons["閉じる"].waitForExistence(timeout: 10) else {
            XCTFail("設定画面が表示されなかった")
            return
        }
        settle()
        capture("settings")

        let signOut = app.buttons["ログアウト"]
        var attempts = 0
        while !signOut.exists, attempts < 5 {
            app.swipeUp()
            attempts += 1
        }
        guard signOut.waitForExistence(timeout: 5) else {
            XCTFail("設定画面に「ログアウト」が見つからなかった")
            return
        }
        signOut.tap()
        // 確認ダイアログにも同名のボタンが出るので、増えた方（後に現れた方）を押す。
        let all = app.buttons.matching(identifier: "ログアウト")
        let appeared = NSPredicate(format: "count >= 2")
        _ = XCTWaiter.wait(for: [expectation(for: appeared, evaluatedWith: all)], timeout: 10)
        let confirm = app.sheets.buttons["ログアウト"]
        if confirm.exists {
            confirm.tap()
        } else {
            all.element(boundBy: all.count - 1).tap()
        }
    }

    /// URL 欄にデモサーバーを入れる。前回値が残っていればそのまま使う。
    @MainActor
    private func enterServerURL() {
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 5) else {
            XCTFail("URL 入力欄が見つからなかった")
            return
        }
        let current = (field.value as? String) ?? ""
        if current == Self.demoServerURL { return }

        field.tap()
        dismissKeyboardTutorial()
        // プレースホルダは value に混ざるので、実際に文字が入っているときだけ消す。
        if !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(Self.demoServerURL)
    }

    /// Quick Connect を開始し、コードが出た状態を撮ってから取り消す。
    /// サーバー側で無効化されていてエラーになった場合も、その見た目を残す。
    @MainActor
    private func captureQuickConnect() {
        let quickConnect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Quick Connect'")).firstMatch
        guard quickConnect.waitForExistence(timeout: 5) else {
            XCTFail("Quick Connect ボタンが見つからなかった")
            capture("login-quickconnect")
            return
        }
        tapScrollingIntoView(quickConnect)

        // コードが出れば「キャンセル」が現れる。失敗したときはエラー文が出るので、そちらも待ち終わりにする。
        let cancel = app.buttons["キャンセル"]
        let errorText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'エラー' OR label CONTAINS '失敗' OR label CONTAINS 'できません'")
        ).firstMatch
        _ = waitForAny([cancel, errorText], timeout: 15)
        settle()
        capture("login-quickconnect")
        if cancel.exists {
            cancel.tap()
        }
    }

    @MainActor
    private func signInWithPassword() {
        let username = app.textFields["ユーザー名"]
        guard username.waitForExistence(timeout: 5) else {
            XCTFail("ユーザー名の入力欄が見つからなかった")
            return
        }
        tapScrollingIntoView(username)
        dismissKeyboardTutorial()
        username.typeText(Self.demoUser)

        let signIn = app.buttons["ログイン"]
        tapScrollingIntoView(signIn)
    }

    // MARK: - ログイン後の画面

    @MainActor
    func testCaptureAppScreens() throws {
        launchApp()
        ensureSignedIn()

        // ホーム: セクションが出るまで待って読込完了とみなす。
        let recentlyAdded = app.staticTexts["最近追加したアルバム"]
        XCTAssertTrue(recentlyAdded.waitForExistence(timeout: 30), "ホームの読込が終わらなかった")
        settle()
        capture("home")

        // ライブラリ → アルバム一覧 → 先頭のアルバム詳細。
        selectTab("ライブラリ")
        XCTAssertTrue(app.navigationBars["ライブラリ"].waitForExistence(timeout: 10), "ライブラリが表示されなかった")
        settle()
        capture("library")

        app.staticTexts["アルバム"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["アルバム"].waitForExistence(timeout: 10), "アルバム一覧が表示されなかった")
        let firstAlbum = app.scrollViews.firstMatch.buttons.firstMatch
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 20), "アルバムが 1 件も読み込まれなかった")
        settle()
        capture("albums")

        firstAlbum.tap()
        let play = app.buttons["再生"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "アルバム詳細が表示されなかった")
        // 収録曲の読込が終わるまで「再生」は無効なので、有効化を待つ。
        _ = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)], timeout: 20)
        settle()
        capture("album")

        capturePlayerScreens(playButton: play)
        recoverIfTerminated()

        // 検索: 入力前の状態を撮ってから、クエリを入れて結果の行が出るまで待つ。
        selectTab("検索")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "検索欄が表示されなかった")
        settle()
        capture("search-idle")

        searchField.tap()
        dismissKeyboardTutorial()
        // 改行で検索キーを押したことになり、結果を隠すキーボードも閉じる。
        searchField.typeText("a\n")
        let firstResult = app.cells.firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 20), "検索結果が表示されなかった")
        dismissKeyboard()
        settle()
        capture("search")

        XCTAssertTrue(skippedScreens.isEmpty, "撮れなかった画面: \(skippedScreens.joined(separator: ", "))")
    }

    /// ログイン画面だったらデモサーバーへログインしてから進む。
    @MainActor
    private func ensureSignedIn() {
        let settings = app.buttons["設定"]
        let connect = app.buttons["接続"]
        guard waitForAny([settings, connect], timeout: 20) else {
            XCTFail("起動後にホームもログイン画面も表示されなかった")
            return
        }
        if settings.exists { return }

        enterServerURL()
        connect.tap()
        guard app.buttons["サーバーを変更"].waitForExistence(timeout: 20) else {
            XCTFail("デモサーバーに接続できなかった")
            return
        }
        signInWithPassword()
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "デモサーバーにログインできなかった")
    }

    /// 先頭曲を再生し、ミニプレイヤー → フルプレイヤー（アートワーク／歌詞／次に再生）を撮る。
    /// ストリーミングが始まらなければ 4 画面まとめてスキップし、後続の検索へ進む。
    @MainActor
    private func capturePlayerScreens(playButton: XCUIElement) {
        let playerScreens = ["miniplayer", "nowplaying", "lyrics", "queue"]
        guard playButton.isEnabled else {
            skippedScreens += playerScreens
            return
        }
        playButton.tap()

        // 再生が始まるとミニプレイヤーの再生ボタンが「一時停止」になる。
        let pause = app.buttons["一時停止"]
        guard pause.waitForExistence(timeout: 20), isRunning else {
            skippedScreens += playerScreens
            return
        }
        // ミニプレイヤーはタブバー付属のアクセサリなのでどのタブでも見える。アルバム詳細のまま撮る。
        let openPlayer = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'プレイヤーを開く'")).firstMatch
        guard openPlayer.waitForExistence(timeout: 10), isRunning else {
            skippedScreens += playerScreens
            return
        }
        settle()
        capture("miniplayer")

        openPlayer.tap()
        let close = app.buttons["プレイヤーを閉じる"]
        guard close.waitForExistence(timeout: 10), isRunning else {
            skippedScreens += playerScreens.dropFirst()
            return
        }
        settle()
        capture("nowplaying")

        guard isRunning else {
            skippedScreens += ["lyrics", "queue"]
            return
        }
        app.buttons["歌詞"].tap()
        settle()
        capture("lyrics")

        guard isRunning else {
            skippedScreens.append("queue")
            return
        }
        app.buttons["次に再生"].tap()
        settle()
        capture("queue")

        guard isRunning else { return }
        close.tap()
        _ = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: close)], timeout: 5)
    }

    @MainActor
    private var isRunning: Bool { app.state == .runningForeground }

    /// 再生中にアプリが落ちた場合でも残りの画面を撮れるよう、立ち上げ直してホームまで戻す。
    @MainActor
    private func recoverIfTerminated() {
        guard !isRunning else { return }
        XCTFail("再生中にアプリが終了した（クラッシュログを確認すること）")
        launchApp()
        ensureSignedIn()
    }

    /// 検索タブ（`role: .search`）が選ばれている間はタブバーが検索欄に変形して他のタブが消えるので、
    /// まず「Close」で元に戻してから目的のタブを押す。
    @MainActor
    private func selectTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        if !tab.exists {
            let closeSearch = app.tabBars.buttons["Close"]
            if closeSearch.exists { closeSearch.tap() }
        }
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        } else {
            app.buttons[title].firstMatch.tap()
        }
    }

    // MARK: - 補助

    /// 複数の要素のどれかが現れるまで待つ。起動直後の分岐に使う。
    @MainActor
    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return elements.contains(where: { $0.exists })
    }

    /// キーボードに隠れているときはスクロールして押せる位置に出す。
    @MainActor
    private func tapScrollingIntoView(_ element: XCUIElement) {
        var attempts = 0
        while !element.isHittable, attempts < 4 {
            app.swipeUp()
            attempts += 1
        }
        element.tap()
    }

    /// シミュレータ初回のキーボード説明（Continue）が出ていれば閉じる。出たままだと入力が届かない。
    @MainActor
    private func dismissKeyboardTutorial() {
        let tutorialContinue = app.buttons["Continue"]
        if tutorialContinue.waitForExistence(timeout: 1) { tutorialContinue.tap() }
    }

    /// 撮影対象がキーボードに隠れないよう、出ていれば閉じる（各画面は interactive dismiss 対応）。
    @MainActor
    private func dismissKeyboard() {
        dismissKeyboardTutorial()
        guard app.keyboards.firstMatch.exists else { return }
        // interactive dismiss は指がキーボード領域まで入ったときに閉じるので、単純な swipeDown では足りない。
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.1, thenDragTo: end)
        settle()
    }

    /// 遷移アニメーションが終わるのを待ってから撮る。
    @MainActor
    private func settle() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
    }

    /// 結果バンドルへの添付と、比較しやすいようファイルへの書き出しを両方行う。ファイル名は `<画面>.png`。
    @MainActor
    private func capture(_ screen: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let fileName = "\(screen).png"

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)

        if let shotDirectory {
            do {
                try FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
                try screenshot.pngRepresentation.write(to: shotDirectory.appendingPathComponent(fileName))
            } catch {
                XCTFail("スクリーンショットを書き出せなかった: \(fileName) — \(error)")
            }
        }
        capturedNames.insert(screen)
    }
}
