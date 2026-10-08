import Foundation
import XCTest

// MARK: - ログイン画面

extension CaptureScreensUITests {
    @MainActor
    func testAccountHeaderStaysFixedWhenScrolled() throws {
        // 本文が収まる端末でも実際にスクロールさせ、固定位置の回帰を検出する。
        launchApp(contentSizeCategoryOverride: "UICTContentSizeCategoryExtraExtraExtraLarge")
        ensureSignedIn()
        let account = element(.button, "アカウント")
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()

        let title = app.staticTexts["Jellyfin Account"]
        let close = element(.button, "閉じる")
        let quality = app.staticTexts["Audio Quality"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(quality.exists, "音質のカードが表示されなかった")
        settle()
        let titleFrame = title.frame
        let closeFrame = close.frame
        let qualityY = quality.frame.minY
        try captureAccountHeader("account-header-initial")

        app.scrollViews.containing(.staticText, identifier: "Audio Quality").firstMatch.swipeUp(velocity: .slow)
        settle()
        try captureAccountHeader("account-header-scrolled")
        XCTAssertLessThan(quality.frame.minY, qualityY - 10, "本文がスクロールしていなかった")
        XCTAssertTrue(title.isHittable, "見出しが画面外へ移動した")
        XCTAssertTrue(close.isHittable, "閉じるボタンが画面外へ移動した")
        XCTAssertEqual(title.frame.minY, titleFrame.minY, accuracy: 1, "見出しがスクロールした")
        XCTAssertEqual(close.frame.minY, closeFrame.minY, accuracy: 1, "閉じるボタンがスクロールした")
        close.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "アカウント画面が閉じられなかった")
        XCTAssertTrue(account.waitForExistence(timeout: 10), "アカウント画面を閉じられなかった")
    }

    @MainActor
    private func captureAccountHeader(_ name: String) throws {
        // スクロール後の固定ヘッダーも含む、合成済みの画面を記録する。
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["MUSICFIN_SHOT_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(
                to: output.appendingPathComponent("\(name).png"))
        }
    }

    @MainActor
    func testCaptureLoginScreens() throws {
        launchApp()

        // 起動直後はセッション復元でホームかログイン画面のどちらかになる。
        let settings = element(.button, "アカウント")
        let connect = element(.button, "接続")
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

        let changeServer = element(.button, "サーバーを変更")
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
            XCTAssertTrue(element(.staticText, "Jellyfin Account").waitForExistence(timeout: 10), "アカウント画面が表示されなかった")
            settle()
            capture("account")
            element(.button, "閉じる").tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 10), "アカウント画面を閉じられなかった")
        }
    }

    /// ホーム右上の「設定」から設定画面を撮り、確認ダイアログ経由でログアウトする。
    @MainActor
    private func signOutFromHome() {
        element(.button, "アカウント").tap()
        guard element(.staticText, "Jellyfin Account").waitForExistence(timeout: 10) else {
            XCTFail("アカウント画面が表示されなかった")
            return
        }
        settle()
        capture("account")

        let signOut = element(.button, "ログアウト")
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
        let all = app.buttons.matching(identifier: "Sign Out")
        let appeared = NSPredicate(format: "count >= 2")
        _ = XCTWaiter.wait(for: [expectation(for: appeared, evaluatedWith: all)], timeout: 10)
        let confirm = app.sheets.buttons["Sign Out"]
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
        if current == serverURL { return }

        field.tap()
        dismissKeyboardTutorial()
        // プレースホルダは value に混ざるので、実際に文字が入っているときだけ消す。
        if !current.isEmpty, current != field.placeholderValue {
            field.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 2) {
                selectAll.tap()
                field.typeText(XCUIKeyboardKey.delete.rawValue)
            } else {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(current.count, 256)))
            }
        }
        field.typeText(serverURL)
    }

    /// Quick Connect を開始し、コードが出た状態を撮ってから取り消す。
    /// サーバー側で無効化されていてエラーになった場合も、その見た目を残す。
    @MainActor
    private func captureQuickConnect() {
        let quickConnect = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Quick Connect'")).firstMatch
        guard quickConnect.waitForExistence(timeout: 5) else {
            XCTFail("Quick Connect ボタンが見つからなかった")
            capture("login-quickconnect")
            return
        }
        tapScrollingIntoView(quickConnect)

        // コードが出れば「キャンセル」が現れる。失敗したときはエラー文が出るので、そちらも待ち終わりにする。
        let cancel = element(.button, "キャンセル")
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
        let username = element(.textField, "ユーザー名")
        guard username.waitForExistence(timeout: 5) else {
            XCTFail("ユーザー名の入力欄が見つからなかった")
            return
        }
        tapScrollingIntoView(username)
        dismissKeyboardTutorial()
        username.typeText(self.username)

        if !password.isEmpty {
            let passwordField = app.secureTextFields.firstMatch
            guard passwordField.waitForExistence(timeout: 5) else {
                XCTFail("パスワードの入力欄が見つからなかった")
                return
            }
            tapScrollingIntoView(passwordField)
            passwordField.typeText(password)
        }

        let signIn = element(.button, "ログイン")
        guard signIn.waitForExistence(timeout: 5) else {
            XCTFail("ログインボタンが見つからなかった")
            return
        }
        tapScrollingIntoView(signIn)
    }

    /// ログイン画面だったらデモサーバーへログインしてから進む。
    @MainActor
    func ensureSignedIn() {
        let settings = element(.button, "アカウント")
        let connect = element(.button, "接続")
        guard waitForAny([settings, connect], timeout: 20) else {
            XCTFail("起動後にホームもログイン画面も表示されなかった")
            return
        }
        if settings.exists { return }

        enterServerURL()
        connect.tap()
        guard element(.button, "サーバーを変更").waitForExistence(timeout: 20) else {
            XCTFail("デモサーバーに接続できなかった")
            return
        }
        signInWithPassword()
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "デモサーバーにログインできなかった")
    }

    /// ジャンルは全アルバムを読み切るまで進行表示になる。読込中の画面を撮らないよう待つ。
    @MainActor
    func waitForCatalogScan() {
        let progress = element(.staticText, "すべてのアルバムを確認中…")
        let deadline = Date(timeIntervalSinceNow: 60)
        while progress.exists, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
    }

    /// ライブラリ直下まで戻す。詳細まで潜っている場合があるので複数回 pop する。
    @MainActor
    func goBackToLibrary() {
        var attempts = 0
        while !app.buttons["library.account"].exists, attempts < 3 {
            let back = app.navigationBars.buttons.firstMatch
            guard back.waitForExistence(timeout: 3) else { break }
            back.tap()
            attempts += 1
            _ = app.buttons["library.account"].waitForExistence(timeout: 3)
        }
    }
}
