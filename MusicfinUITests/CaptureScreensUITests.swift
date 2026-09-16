import Foundation
import XCTest

/// 主要画面を同じ手順で撮影し、`docs/screenshots/manifest.json`（スクリプトが生成）経由で比較できるようにする。
/// 保存先は `MUSICFIN_SHOT_DIR` で受け取る。
/// 文字サイズは `MUSICFIN_CONTENT_SIZE` で受け取る（例 `UICTContentSizeCategoryAccessibilityXXXL`）。
/// 未指定なら Simulator の既定サイズのままにする。
/// 表示ラベルを基本とし、同名操作を区別できない箇所だけ安定した識別子を使う。
final class CaptureScreensUITests: XCTestCase {
    private static let defaultServerURL = "https://jellyfin.tkgstrator.work"
    private static let defaultUsername = "demo"
    private static let replyItemID = "edbbb8025d78bddebb6360962b27df89"
    private static let rayItemID = "43612d6d33406faf4cbaba89f5bd427b"
    private static let meltItemID = "92bdf95b3902c28a2bc147d651a9f63f"
    private static let togenashiTogeariArtistID = "f739583459f481ecc459cee23e70fc3d"
    private static let heartOnMySleeveAlbumID = "67c8bdd170cbb7e32ef9b0dd6b8f7b69"
    private static let cosmicAlbumID = "982d12de5338d828ea535c7aa65e0e05"
    private static let cosmicReferenceTitle = "Cosmic Princess Kaguya!"

    private struct APIAuthentication: Decodable {
        struct User: Decodable {
            let id: String
            private enum CodingKeys: String, CodingKey { case id = "Id" }
        }
        let user: User
        let accessToken: String

        private enum CodingKeys: String, CodingKey {
            case user = "User"
            case accessToken = "AccessToken"
        }
    }

    private struct APISearchResult: Decodable {
        struct Item: Decodable {
            let id: String
            let name: String
            let type: String
            let parentID: String?

            private enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
                case type = "Type"
                case parentID = "ParentId"
            }
        }
        let items: [Item]

        private enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    private var serverURL: String {
        ProcessInfo.processInfo.environment["MUSICFIN_SERVER_URL"] ?? Self.defaultServerURL
    }

    private var username: String {
        ProcessInfo.processInfo.environment["MUSICFIN_USERNAME"] ?? Self.defaultUsername
    }

    private var password: String {
        ProcessInfo.processInfo.environment["MUSICFIN_PASSWORD"] ?? ""
    }

    private var captureBridgeDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["MUSICFIN_CAPTURE_BRIDGE_DIR"],
            !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // XCUIApplication は MainActor 隔離なので、テスト本体と補助メソッドを MainActor に置く。
    // クラス自体を MainActor にすると XCTestCase の nonisolated な override と衝突する。
    private var app: XCUIApplication!
    private var shotDirectory: URL?
    /// `UICTContentSizeCategory…` の名前をそのまま持つ。未指定なら nil。
    private var contentSizeCategory: String?
    private var capturedNames: Set<String> = []
    private var skippedScreens: [String] = []

    private var isIPadCapture: Bool {
        ProcessInfo.processInfo.environment["MUSICFIN_IPAD_CAPTURE"] == "1"
    }

    /// 英語固定の撮影でも同じ操作手順を使えるよう、既存の日本語ラベルを英訳して検索する。
    @MainActor
    private func element(_ type: XCUIElement.ElementType, _ japanese: String) -> XCUIElement {
        let english: [String: String] = [
            "アカウント": "Account", "接続": "Connect", "サーバーを変更": "Change Server",
            "閉じる": "Close", "ログアウト": "Sign Out", "キャンセル": "Cancel",
            "ユーザー名": "Username", "ログイン": "Sign In", "最近追加したアルバム": "Recently Added Albums",
            "ライブラリ": "Library", "アルバム": "Albums", "アーティスト": "Artists", "プレイリスト": "Playlists",
            "ジャンル": "Genres", "曲": "Songs", "お気に入りの曲": "Favorite Songs", "再生": "Play", "歌詞": "Lyrics",
            "すべてのアルバムを確認中…": "Loading all albums…", "一時停止": "Pause", "次に再生": "Play Next",
            "アルバムがありません": "No Albums",
        ]
        return app.descendants(matching: type)[english[japanese] ?? japanese]
    }

    override func setUpWithError() throws {
        // 1 つの画面が撮れなくても残りは撮り切りたい。
        continueAfterFailure = true
        // 画面遷移と実 API 待機を 1 method で行うため、Xcode の 1 分既定値では完走できない。
        executionTimeAllowance = 1_800

        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["MUSICFIN_SHOT_DIR"], !directory.isEmpty {
            shotDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        }
        if let category = environment["MUSICFIN_CONTENT_SIZE"], !category.isEmpty {
            contentSizeCategory = category
        }
    }

    @MainActor
    private func launchApp(capturePlayer: Bool = false) {
        // 前の method の Simulator 状態に依存せず、毎回 portrait から実際の横向き遷移を起こす。
        if isIPadCapture {
            XCUIDevice.shared.orientation = .portrait
        }
        app = XCUIApplication()
        app.launchEnvironment["MUSICFIN_SHOT_DIR"] = shotDirectory?.path ?? ""
        if capturePlayer { app.launchEnvironment["MUSICFIN_CAPTURE_PLAYER"] = "1" }
        // test runner のロケールは app 子プロセスへ継承されないため、比較条件を起動引数と環境の両方で固定する。
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["AppleLanguages"] = "(en)"
        app.launchEnvironment["AppleLocale"] = "en_US"
        // 文字サイズは起動引数でしか差し替えられない（Simulator 全体の設定を触らずに済む）。
        // 未指定のときは引数ごと足さないので、既定の撮影は今までと同じ経路を通る。
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        if isIPadCapture {
            ensureIPadLandscape()
        }
    }

    /// orientation の設定値ではなく app window の実寸を待ち、Air 系で遷移が遅れても縦画面を撮らない。
    @MainActor
    private func ensureIPadLandscape() {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 10) else {
            XCTFail("iPad の app window が表示されなかった（orientation: \(XCUIDevice.shared.orientation.rawValue)）")
            return
        }

        for _ in 0..<3 {
            XCUIDevice.shared.orientation = .portrait
            app.activate()
            _ = waitForWindow(window, landscape: false, timeout: 5)

            XCUIDevice.shared.orientation = .landscapeLeft
            // 回転イベントは app が前面のまま発火させる。設定直後の activate は scene を
            // portrait geometry で再アクティブ化し、Air 系では要求を打ち消してしまう。
            if waitForWindow(window, landscape: true, timeout: 10) {
                let image = XCUIScreen.main.screenshot().image
                XCTAssertEqual(image.size.width * image.scale, 2732, "iPad 撮影開始前の幅が参照と異なる")
                XCTAssertEqual(image.size.height * image.scale, 2048, "iPad 撮影開始前の高さが参照と異なる")
                return
            }
        }

        let frame = window.frame
        XCTFail(
            "iPad が横向きにならなかった（frame: \(frame.width)×\(frame.height), orientation: \(XCUIDevice.shared.orientation.rawValue)）"
        )
    }

    /// CoreSimulator の回転完了は非同期なので、window の縦横が目的どおりになるまでだけ bounded wait する。
    @MainActor
    private func waitForWindow(_ window: XCUIElement, landscape: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let frame = window.frame
            if landscape ? frame.width > frame.height : frame.height > frame.width { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        let frame = window.frame
        return landscape ? frame.width > frame.height : frame.height > frame.width
    }

    // MARK: - ログイン画面

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

    // MARK: - ログイン後の画面

    /// iPad の配置だけを再撮影し、再生状態や参照曲の検索失敗から独立して検証する。
    @MainActor
    func testCaptureIPadLayoutRegression() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の撮影") }
        launchApp()
        ensureSignedIn()

        let account = element(.button, "アカウント")
        XCTAssertTrue(account.waitForExistence(timeout: 30), "ホームが表示されなかった")
        settle()
        capture("home")

        app.buttons["sidebar.search"].tap()
        let searchField = searchFieldElement
        XCTAssertTrue(searchField.waitForExistence(timeout: 20), "iPad の検索欄が表示されなかった")
        // 入力前のジャンルタイルは全アルバムを辿ってから並ぶ。読込中の輪だけを撮っても配置の比較にならない。
        _ = app.activityIndicators.firstMatch.waitForNonExistence(timeout: 90)
        settle()
        capture("search-idle")

        // 結果一覧は参照曲の item ID に依存させない。並びやデモデータが変わっても崩れないよう、
        // 多くの item が引っ掛かる語で「1 件でも出た」ことだけを待つ。
        XCTAssertTrue(typeSearchQuery(searchField, "Ray"), "検索欄に語を入れられなかった")
        searchField.typeText("\n")
        let anyResult = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search.result.")
        ).firstMatch
        XCTAssertTrue(anyResult.waitForExistence(timeout: 30), "検索結果が 1 件も出なかった")
        dismissKeyboard()
        settle()
        capture("search")

        capturePadSidebarChild(identifier: "sidebar.artists", title: "アーティスト", screen: "artists")
        capturePadSidebarChild(identifier: "sidebar.songs", title: "曲", screen: "songs")
        app.buttons["sidebar.albums"].tap()
        let firstAlbum = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "album.card.")
        ).firstMatch
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 30), "アルバムが 1 件も読み込まれなかった")
        settle()
        capture("albums")
    }

    @MainActor
    func testCaptureIPadPlayer() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の撮影") }
        launchApp(capturePlayer: true)
        XCTAssertTrue(element(.button, "歌詞").waitForExistence(timeout: 15), "iPad full player が表示されなかった")
        settle()
        capture("playing")
    }

    @MainActor
    func testCaptureAppScreens() throws {
        launchApp()
        ensureSignedIn()

        // 3 画面の参照は同じ Ray を停止したミニプレイヤー付きで撮られているため、先に状態を固定する。
        XCTAssertTrue(preparePausedRay(), "参照と同じ Ray の停止状態を作れなかった")
        selectTab("ホーム")

        // ホーム: セクションが出るまで待って読込完了とみなす。
        let recentlyAdded = element(.staticText, "最近追加したアルバム")
        let account = element(.button, "アカウント")
        XCTAssertTrue(
            waitForAny([recentlyAdded, account], timeout: 30),
            "ホームが表示されなかった"
        )
        settle()
        capture("home")
        if isIPadCapture, account.exists {
            account.tap()
            XCTAssertTrue(element(.staticText, "Jellyfin Account").waitForExistence(timeout: 10), "アカウント画面が表示されなかった")
            settle()
            capture("account")
            element(.button, "閉じる").tap()
            XCTAssertTrue(account.waitForExistence(timeout: 10), "アカウント画面を閉じられなかった")
        }

        // iPad は sidebar から各一覧を直接 detail root に出し、iPhone だけライブラリ入口を経由する。
        if isIPadCapture {
            capturePadSidebarChild(identifier: "sidebar.artists", title: "アーティスト", screen: "artists") {
                self.captureArtistDetail()
            }
            capturePadSidebarChild(identifier: "sidebar.songs", title: "曲", screen: "songs")
            app.buttons["sidebar.albums"].tap()
        } else {
            selectTab("ライブラリ")
            XCTAssertTrue(
                element(.staticText, "ライブラリ").firstMatch.waitForExistence(timeout: 10),
                "ライブラリが表示されなかった")
            settle()
            capture("library")

            captureLibraryChild(
                row: "アーティスト", title: "アーティスト", screen: "artists",
                dependents: ["artist"]
            ) {
                self.captureArtistDetail()
            }
            captureLibraryChild(
                row: "プレイリスト", title: "プレイリスト", screen: "playlists",
                dependents: ["playlist"]
            ) {
                self.capturePlaylistDetail()
            }
            captureLibraryChild(row: "ジャンル", title: "ジャンル", screen: "genres")
            captureLibraryChild(row: "曲", title: "曲", screen: "songs")
            captureLibraryChild(row: "お気に入りの曲", title: "お気に入りの曲", screen: "favorites")
            app.buttons["library.albums"].tap()
        }
        // 位置で引くと一覧の先頭にある「再生」を掴んでしまい、詳細ではなく一覧が撮れる。
        let firstAlbum = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.card.")).firstMatch
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 20), "アルバムが 1 件も読み込まれなかった")
        if !isIPadCapture {
            let actions = app.otherElements["library.albums.actions"]
            XCTAssertTrue(actions.waitForExistence(timeout: 5), "アルバムの固定再生操作が表示されなかった")
            firstAlbum.swipeUp(velocity: .slow)
            XCTAssertTrue(actions.isHittable, "検索欄の折り畳み後に再生操作が固定されなかった")
        }
        settle()
        capture("albums")

        // Apple Music 参照と同じ作品だけを検索結果から開き、別のアルバムで代用しない。
        guard openCosmicAlbum() != nil else {
            XCTFail("Reply の親アルバムを開けず、album を撮影できなかった")
            skippedScreens.append("album")
            return
        }
        XCTAssertEqual(app.buttons["miniplayer.play-pause"].label, "Play", "Cosmic 詳細で Ray が停止していない")
        settle()
        capture("album")
        if isIPadCapture {
            // 詳細の NavigationPath を残したまま sidebar を切り替えると検索欄が出ないことがあるため、
            // Search の 3 枚は新しい scene のルートから始める。
            launchApp()
            ensureSignedIn()
            captureIPadSearchDetails()
        }

        // Apple Music の参照と同じ曲を検索結果から選び、実際の歌詞が出た個体だけをプレイヤー撮影に使う。
        launchApp()
        ensureSignedIn()
        captureReplyPlayerScreens()
        recoverIfTerminated()
        if isIPadCapture {
            XCTAssertTrue(skippedScreens.isEmpty, "撮れなかった画面: \(skippedScreens.joined(separator: ", "))")
            return
        }

        // 検索: 入力前の状態を撮ってから、クエリを入れて結果の行が出るまで待つ。
        selectTab("検索")
        let searchField = searchFieldElement
        // ここで打ち切ると以降の撮影が全部落ちるので、撮れない画面は記録だけして最後まで進む。
        if searchField.waitForExistence(timeout: 10) {
            settle()
            capture("search-idle")

            // 入力を始めるとタイルが結果に置き換わるので、遷移の 2 枚を先に撮る。
            captureSearchPush()

            searchField.tap()
            dismissKeyboardTutorial()
            // Apple Music と同じく「入力中」も比較対象なので、確定前に 1 枚撮る。
            searchField.typeText("a")
            settle()
            capture("search-typing")

            // 改行で検索キーを押したことになり、結果を隠すキーボードも閉じる。
            searchField.typeText("\n")
            if app.cells.firstMatch.waitForExistence(timeout: 20) {
                dismissKeyboard()
                settle()
                capture("search")
            } else {
                skippedScreens.append("search")
            }
        } else {
            skippedScreens += [
                "search-idle", "search-push", "search-pop", "search-typing", "search",
            ]
        }

        XCTAssertTrue(skippedScreens.isEmpty, "撮れなかった画面: \(skippedScreens.joined(separator: ", "))")
    }

    /// iPad の sidebar 項目を直接 detail root に出し、深い遷移が残っていても次の選択で破棄する。
    @MainActor
    private func capturePadSidebarChild(
        identifier: String, title: String, screen: String, then drillDown: (() -> Void)? = nil
    ) {
        let sidebar = app.buttons[identifier]
        guard sidebar.waitForExistence(timeout: 10) else {
            skippedScreens.append(screen)
            return
        }
        sidebar.tap()
        guard element(.navigationBar, title).waitForExistence(timeout: 20) else {
            skippedScreens.append(screen)
            return
        }
        let loaded: Bool
        switch identifier {
        case "sidebar.artists":
            loaded = waitForAny(
                [
                    app.buttons.matching(
                        NSPredicate(format: "identifier BEGINSWITH %@", "artist.row.")
                    )
                    .firstMatch,
                    element(.staticText, "アーティストがありません"),
                ],
                timeout: 20)
        case "sidebar.songs":
            loaded = waitForAny(
                [app.buttons["song.row"].firstMatch, element(.staticText, "曲がありません")],
                timeout: 20)
        default:
            loaded = true
        }
        guard loaded else {
            XCTFail("iPad sidebar の遷移先を読み込めなかった: \(identifier)")
            skippedScreens.append(screen)
            return
        }
        settle()
        capture(screen)
        drillDown?()
    }

    /// ライブラリの行から遷移して 1 画面撮り、必ずライブラリ直下へ戻す。
    /// 1 画面の失敗で後続が全部落ちないよう、待てなければ記録して戻るだけにする。
    /// `dependents` は `drillDown` がさらに潜って撮る画面。ここで先に抜けると `drillDown` へ届かず、
    /// その名前が未撮影の記録から漏れるので、撮影はせず記録だけ肩代わりする。
    @MainActor
    private func captureLibraryChild(
        row: String, title: String, screen: String, dependents: [String] = [],
        then drillDown: (() -> Void)? = nil
    ) {
        guard app.buttons["library.account"].waitForExistence(timeout: 10) else {
            skippedScreens += [screen] + dependents
            return
        }
        let routeNames = [
            "アーティスト": "artists", "プレイリスト": "playlists", "ジャンル": "genres", "曲": "songs", "お気に入りの曲": "favorites",
        ]
        app.buttons["library.\(routeNames[row] ?? row)"].tap()
        guard element(.navigationBar, title).waitForExistence(timeout: 20) else {
            skippedScreens += [screen] + dependents
            goBackToLibrary()
            return
        }
        waitForCatalogScan()
        settle()
        capture(screen)
        drillDown?()
        goBackToLibrary()
    }

    /// アーティスト一覧からアルバムを持つ 1 件を開いて詳細を撮る。戻りは `goBackToLibrary` の多段 pop に任せる。
    /// 先頭固定にすると、アルバムを持たないアーティストの空のグリッドが撮れたまま撮影が通ってしまう。
    @MainActor
    private func captureArtistDetail() {
        let artists = app.cells
        guard artists.firstMatch.waitForExistence(timeout: 20) else {
            skippedScreens.append("artist")
            return
        }
        guard let referenceArtist = apiItem(id: Self.togenashiTogeariArtistID) else {
            XCTFail("参照アーティストを Jellyfin API で確認できなかった")
            skippedScreens.append("artist")
            return
        }
        let artist = app.buttons["artist.row.\(referenceArtist.id)"]
        if !artist.exists {
            let search = listSearchField
            if search.waitForExistence(timeout: 5) {
                search.tap()
                dismissKeyboardTutorial()
                search.tap()
                search.typeText(referenceArtist.name + "\n")
            }
        }
        guard artist.waitForExistence(timeout: 10) else {
            XCTFail("参照アーティストが Library 一覧に見つからなかった")
            skippedScreens.append("artist")
            return
        }
        artist.tap()
        guard app.navigationBars.buttons["Artists"].waitForExistence(timeout: 20) else {
            XCTFail("参照アーティスト詳細へ遷移しなかった")
            skippedScreens.append("artist")
            return
        }
        guard
            app.descendants(matching: .any)["artist.detail.loaded"]
                .waitForExistence(timeout: 30)
        else {
            XCTFail("Library のアーティスト詳細が依存データを読み終えなかった")
            skippedScreens.append("artist")
            return
        }
        settle()
        capture("artist")
    }

    /// プレイリスト一覧の先頭を開いて詳細を撮る。戻りは `goBackToLibrary` の多段 pop に任せる。
    /// `continueAfterFailure` が true なので、待てなかったときは `XCTFail` だけでは止まらない。
    /// 0 件・0 曲の画面を代用として残さないよう、どの失敗も `guard` で必ず抜ける。
    @MainActor
    private func capturePlaylistDetail() {
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "playlist.row.")
        )
        .firstMatch
        guard row.waitForExistence(timeout: 20) else {
            XCTFail("プレイリストが 1 件も読み込まれず、playlist 画面を撮れなかった")
            skippedScreens.append("playlist")
            return
        }
        row.tap()

        // 「再生」は一覧にも在るので到達の証拠にしない。題名の出現と一覧の消失で確かめる。
        let detail = app.staticTexts["playlist.detail"]
        guard detail.waitForExistence(timeout: 20), waitForDisappearance(of: row, timeout: 10) else {
            XCTFail("プレイリスト詳細へ遷移しなかった")
            skippedScreens.append("playlist")
            return
        }
        // 曲が出るまで待たないと、読込中の空の一覧が撮れてしまう。
        guard
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "playlist.track."))
                .firstMatch.waitForExistence(timeout: 20)
        else {
            XCTFail("プレイリストの曲が 1 件も出ず、playlist 画面を撮れなかった")
            skippedScreens.append("playlist")
            return
        }
        settle()
        // ここで再生を始めると後続のアルバム・プレイヤー撮影の状態が変わるので、撮るだけで戻る。
        capture("playlist")
    }

    /// 参照 3 画面で共通する `ray (超かぐや姫! Version)` を ID で選び、停止状態へ固定する。
    @MainActor
    private func preparePausedRay() -> Bool {
        guard let ray = apiItem(id: Self.rayItemID), ray.type == "Audio" else {
            XCTFail("Ray の item ID を API で確認できなかった")
            return false
        }
        selectTab("検索")
        let searchField = searchFieldElement
        guard searchField.waitForExistence(timeout: 10) else { return false }
        searchField.tap()
        dismissKeyboardTutorial()
        let clear = app.buttons["Clear text"]
        if clear.exists {
            clear.tap()
            searchField.tap()
        }
        // 長い日本語名を Simulator へ一括注入すると XCUITest runner が終了するため、
        // 同じ item を返す短い ASCII 語で UI と API の検索条件を揃える。
        guard typeSearchQuery(searchField, "Ray") else {
            XCTFail("検索欄に Ray を入れられなかった: \(enteredText(of: searchField))")
            return false
        }
        searchField.typeText("\n")

        // 表示順は Jellyfin の検索順に左右されるので、行は item ID の識別子で選ぶ。
        // API の並びから index を数える旧方式は、UI と API で並びが違うと別の同名曲を掴む。
        let target = app.buttons["search.result.Audio.\(ray.id)"]
        guard target.waitForExistence(timeout: 20) else {
            XCTFail("Ray の検索結果 (\(ray.id)) が UI に見つからなかった")
            return false
        }
        target.tap()

        let pause = app.buttons["miniplayer.play-pause"]
        guard pause.waitForExistence(timeout: 40), pause.label == "Pause" else {
            XCTFail("Ray の再生開始を確認できなかった")
            return false
        }
        pause.tap()
        let stopped = expectation(
            for: NSPredicate(format: "label == %@", "Play"), evaluatedWith: pause
        )
        guard XCTWaiter.wait(for: [stopped], timeout: 5) == .completed else {
            XCTFail("Ray を停止できなかった")
            return false
        }
        let openPlayer = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ AND label ENDSWITH %@", ray.name, "Open Player")
        ).firstMatch
        guard openPlayer.waitForExistence(timeout: 10) else {
            XCTFail("停止したミニプレイヤーが Ray ではなかった")
            return false
        }
        return true
    }

    /// Library の album item ID から参照作品を直接開き、検索結果の並びには依存しない。
    @MainActor
    private func openCosmicAlbum() -> XCUIElement? {
        guard let parentID = replyItem()?.parentID, parentID == Self.cosmicAlbumID else {
            XCTFail("Reply の親アルバム ID が参照作品と一致しなかった")
            return nil
        }
        let albumCard = app.buttons["album.card.\(Self.cosmicAlbumID)"]
        if !albumCard.exists {
            if isIPadCapture {
                app.buttons["sidebar.albums"].tap()
            } else if app.buttons["library.account"].exists {
                app.buttons["library.albums"].tap()
            } else {
                goBackToLibrary()
                guard app.buttons["library.account"].waitForExistence(timeout: 10) else {
                    XCTFail("Cosmic を開く前に Library 直下へ戻れなかった")
                    return nil
                }
                app.buttons["library.albums"].tap()
            }
        }
        if !albumCard.waitForExistence(timeout: 10) {
            let search = listSearchField
            if search.waitForExistence(timeout: 5) {
                search.tap()
                dismissKeyboardTutorial()
                search.tap()
                search.typeText(Self.cosmicReferenceTitle + "\n")
            }
        }
        if albumCard.waitForExistence(timeout: 20) {
            albumCard.tap()
        } else {
            // Library はページング済み範囲だけを絞り込むため、後方の参照作品は exact ID の Search 結果から開く。
            selectTab("検索")
            guard let album = apiItem(id: parentID),
                openSearchResult(
                    query: album.name,
                    identifier: "search.result.MusicAlbum.\(parentID)",
                    detailIdentifier: "album.detail"
                )
            else {
                XCTFail("Library または Search に Reply の親アルバムが無かった: \(parentID)")
                return nil
            }
        }
        guard app.staticTexts["album.detail"].waitForExistence(timeout: 20) else {
            XCTFail("Reply の親アルバム詳細へ遷移しなかった: \(parentID)")
            return nil
        }
        return waitForLoadedAlbumDetail()
    }

    /// 収録曲が 2 曲以上あるアルバムを探して開き、その詳細の「再生」を返す。
    /// `queue` の待機曲は「再生した曲より後ろに曲があること」でしか作れないので、曲数は**開いて数える**。
    /// 一覧のカードからは曲数が読めず、名前や並び順から推測すると 1 曲のアルバムを引いたときに黙って空になる。
    /// 見つからなければ `nil` を返すが、**その場合も先頭のアルバム詳細を開いた状態で返す**。
    /// 呼び出し側はそこの「再生」で従来どおり 4 画面を撮り切れる（撮影を落とさないためのフォールバック）。
    @MainActor
    private func openAlbumWithUpcomingTracks(maxAlbums: Int = 6) -> XCUIElement? {
        guard goBackToAlbums() else {
            XCTFail("アルバム一覧へ戻れず、再生元のアルバムを選べなかった")
            return nil
        }
        // 再生した 1 曲目の後ろに 1 曲でも残れば待機曲が出る。
        if let play = openAlbum(minimumTracks: 2, maxAlbums: maxAlbums) { return play }
        XCTFail("収録曲が 2 曲以上のアルバムが見つからず、queue に待機曲を出せない")
        // 見つからなくても 4 画面は撮り切る。空の `queue` でも、撮れない 4 枚より欠落が少ない。
        return nil
    }

    /// 曲行が `minimumTracks` 以上あるアルバムを開き、その詳細の「再生」を返す。
    /// アルバム一覧に居ることが前提。見つからなければ**先頭のアルバムを開いたうえで** nil を返すので、
    /// 呼び出し側は撮影を諦めずに済む。デモサーバーの中身は変わり得るので、条件を満たす保証はない。
    @MainActor
    private func openAlbum(minimumTracks: Int, maxAlbums: Int = 8) -> XCUIElement? {
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.card."))
        // 先頭も候補に入れる。1 曲だと分かっていても、決め打ちにすると撮影データが変わったとき黙ってずれる。
        for index in 0..<min(cards.count, maxAlbums) {
            let card = cards.element(boundBy: index)
            guard card.exists else { break }
            card.tap()
            if let play = waitForLoadedAlbumDetail(),
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.track.")).count
                    >= minimumTracks
            {
                return play
            }
            guard goBackToAlbums() else { return nil }
        }

        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.card.")).firstMatch
        if first.exists {
            first.tap()
            _ = waitForLoadedAlbumDetail()
        }
        return nil
    }

    /// アルバム詳細が開き、収録曲の読込が終わって「再生」が押せるようになるまで待つ。
    /// 読込中は「再生」が無効で曲行も 0 件なので、ここを待たずに数えると 2 曲以上でも 1 曲以下に見える。
    @MainActor
    private func waitForLoadedAlbumDetail() -> XCUIElement? {
        guard app.staticTexts["album.detail"].waitForExistence(timeout: 20) else { return nil }
        let play = app.buttons.matching(identifier: "album.play").firstMatch
        guard play.waitForExistence(timeout: 10) else { return nil }
        _ = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)],
            timeout: 20)
        return play.isEnabled ? play : nil
    }

    /// アルバム詳細からアルバム一覧へ戻す。既に一覧なら何もしない。
    @MainActor
    private func goBackToAlbums() -> Bool {
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.card.")).firstMatch
        var attempts = 0
        while !cards.exists, attempts < 3 {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
            attempts += 1
            settle()
        }
        return cards.waitForExistence(timeout: 10)
    }

    /// iPad の参照で指定された実体を Search 結果から開き、Library の似た画面を代用しない。
    @MainActor
    private func captureIPadSearchDetails() {
        selectTab("検索")
        let searchField = searchFieldElement
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("iPad Search の検索欄が表示されなかった")
            skippedScreens += [
                "search-idle", "search", "search-artist", "search-artist-bottom",
                "search-album-detail",
            ]
            return
        }
        // 入力前と結果一覧は iPad でも比較対象。検索欄の左端が detail 本文と揃うかはこの 2 枚でしか見えない。
        settle()
        capture("search-idle")

        guard
            openSearchResult(
                query: "トゲナシトゲアリ",
                identifier: "search.result.MusicArtist.\(Self.togenashiTogeariArtistID)",
                detailTitle: "トゲナシトゲアリ",
                captureResults: "search"
            )
        else {
            skippedScreens += ["search", "search-artist", "search-artist-bottom"]
            return
        }
        guard
            app.descendants(matching: .any)["artist.detail.loaded"]
                .waitForExistence(timeout: 30)
        else {
            XCTFail("Search のアーティスト詳細が依存データを読み終えなかった")
            skippedScreens += ["search-artist", "search-artist-bottom"]
            return
        }
        settle()
        capture("search-artist")
        let playlists = app.descendants(matching: .any)["artist.section.playlists"]
        let singles = app.descendants(matching: .any)["artist.section.singles-eps"]
        let similar = app.descendants(matching: .any)["artist.section.similar-artists"]
        let similarCard = app.buttons.matching(identifier: "artist.similar.card").firstMatch
        let viewport = app.scrollViews.matching(identifier: "artist.detail.viewport").firstMatch
        guard playlists.exists, singles.exists else {
            XCTFail("Artist Playlists または Singles & EPs セクションが無かった")
            skippedScreens.append("search-artist-bottom")
            return
        }
        func bottomContentIsContained() -> Bool {
            guard viewport.exists, similar.exists, similarCard.exists else { return false }
            let visibleFrame = viewport.frame
            return !visibleFrame.isEmpty && visibleFrame.contains(similar.frame)
                && visibleFrame.contains(similarCard.frame)
        }
        var scrollAttempts = 0
        while !bottomContentIsContained(), scrollAttempts < 8 {
            viewport.swipeUp()
            scrollAttempts += 1
        }
        guard bottomContentIsContained() else {
            XCTFail("Similar Artists の見出しと実データを detail 表示領域内へ収められなかった")
            skippedScreens.append("search-artist-bottom")
            return
        }
        XCTAssertTrue(app.staticTexts["トゲナシトゲアリ"].exists, "Search のアーティスト詳細が別の実体へ変わった")
        settle()
        capture("search-artist-bottom")

        // アーティスト配下の先頭カードではなく、Search の exact item ID から参照のアルバムを開く。
        let backToSearch = app.navigationBars.buttons["Search"]
        guard backToSearch.waitForExistence(timeout: 10) else {
            XCTFail("アーティスト詳細から Search へ戻れなかった")
            skippedScreens.append("search-album-detail")
            return
        }
        backToSearch.tap()
        guard
            openSearchResult(
                query: "全部をさらして生きてやる",
                identifier: "search.result.MusicAlbum.\(Self.heartOnMySleeveAlbumID)",
                detailTitle: "全部をさらして生きてやる"
            )
        else {
            skippedScreens.append("search-album-detail")
            return
        }
        settle()
        capture("search-album-detail")
    }

    /// 検索語を毎回全消去してから指定し、Jellyfin item ID が一致する結果だけを開く。
    @MainActor
    /// `captureResults` を渡すと、結果が出てから開く前に一覧を 1 枚撮る。
    private func openSearchResult(
        query: String, identifier: String, detailTitle: String? = nil,
        detailIdentifier: String? = nil, captureResults: String? = nil
    ) -> Bool {
        let searchField = searchFieldElement
        guard searchField.waitForExistence(timeout: 10) else { return false }
        searchField.tap()
        let clear = app.buttons["Clear text"]
        if clear.exists {
            clear.tap()
            searchField.tap()
        }
        guard typeSearchQuery(searchField, query) else {
            XCTFail("検索欄に語を入れられなかった: \(query) / \(enteredText(of: searchField))")
            return false
        }
        searchField.typeText("\n")
        let result = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard result.waitForExistence(timeout: 20) else {
            XCTFail("Search に指定結果が無かった: \(identifier)")
            return false
        }
        if let captureResults {
            // 結果を隠すキーボードを閉じてから撮る。開いたままだと一覧が半分しか写らない。
            dismissKeyboard()
            settle()
            capture(captureResults)
        }
        result.tap()
        let detail: XCUIElement
        if let detailIdentifier {
            detail = app.staticTexts[detailIdentifier]
        } else if let detailTitle {
            detail = app.staticTexts[detailTitle]
        } else {
            return true
        }
        guard detail.waitForExistence(timeout: 20) else {
            XCTFail("Search から指定詳細へ遷移しなかった: \(detailTitle ?? detailIdentifier ?? identifier)")
            return false
        }
        return true
    }

    /// 検索タブの中の遷移を 2 枚撮る。ライブラリ経由の `albums` や入力前の `search-idle` では、
    /// 「押した直後に largeTitle と検索欄が出るか」「戻った直後に `.inlineLarge` へ復帰するか」を確かめられない。
    @MainActor
    private func captureSearchPush() {
        let tiles = app.scrollViews.buttons
        guard tiles.firstMatch.waitForExistence(timeout: 20) else {
            XCTFail("検索のジャンルタイルが 1 件も出ず、search-push 画面を撮れなかった")
            skippedScreens += ["search-push", "search-pop"]
            return
        }
        // 遷移先にもスクロール内のボタンが在るので、firstMatch では戻りを判定できない。押した札を覚えておく。
        let genre = tiles.firstMatch.label
        tiles.firstMatch.tap()

        // 遷移先の navigationTitle はジャンル名で事前に分からないので、戻るボタンの文字で到達を判定する。
        let back = app.navigationBars.buttons["Search"]
        guard back.waitForExistence(timeout: 20) else {
            XCTFail("検索のタイルからアルバム一覧へ遷移しなかった")
            skippedScreens += ["search-push", "search-pop"]
            return
        }
        // 読込中の空のグリッドを代用として残さないよう、カードが出るまで待つ。
        guard
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.card.")).firstMatch
                .waitForExistence(timeout: 20)
        else {
            XCTFail("ジャンルのアルバムが 1 件も出ず、search-push 画面を撮れなかった")
            skippedScreens += ["search-push", "search-pop"]
            return
        }
        settle()
        capture("search-push")

        back.tap()
        guard tiles[genre].waitForExistence(timeout: 20) else {
            XCTFail("検索のルートへ戻れず、search-pop 画面を撮れなかった")
            skippedScreens.append("search-pop")
            return
        }
        settle()
        capture("search-pop")
    }

    /// ジャンルは全アルバムを読み切るまで進行表示になる。読込中の画面を撮らないよう待つ。
    @MainActor
    private func waitForCatalogScan() {
        let progress = element(.staticText, "すべてのアルバムを確認中…")
        let deadline = Date(timeIntervalSinceNow: 60)
        while progress.exists, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
    }

    /// ライブラリ直下まで戻す。詳細まで潜っている場合があるので複数回 pop する。
    @MainActor
    private func goBackToLibrary() {
        var attempts = 0
        while !app.buttons["library.account"].exists, attempts < 3 {
            let back = app.navigationBars.buttons.firstMatch
            guard back.waitForExistence(timeout: 3) else { break }
            back.tap()
            attempts += 1
            _ = app.buttons["library.account"].waitForExistence(timeout: 3)
        }
    }

    /// ログイン画面だったらデモサーバーへログインしてから進む。
    @MainActor
    private func ensureSignedIn() {
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

    /// Apple Music の参照と同じ `Reply` を検索結果から選び、歌詞を含むプレイヤー一式を撮る。
    /// 同名曲が複数あるため、API で歌詞登録を確認した並びの個体を使い、画面上でも曲名と歌詞本文を検証する。
    @MainActor
    private func captureReplyPlayerScreens() {
        let playerScreens = ["miniplayer", "nowplaying", "lyrics-loading", "lyrics", "queue"]
        selectTab("検索")
        let searchField = searchFieldElement
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Reply の親アルバムを検索する欄が表示されなかった")
            skippedScreens += playerScreens
            return
        }
        // 途中で失敗しても、後続の検索画面は必ず未入力かつ player を閉じた状態から始める。
        defer { cleanupReplyCapture(searchField: searchField) }
        guard openCosmicAlbum() != nil else {
            XCTFail("Reply の exact parent album を開けなかった")
            skippedScreens += playerScreens
            return
        }
        let replyTrack = app.buttons["album.track.\(Self.replyItemID)"]
        guard replyTrack.waitForExistence(timeout: 20) else {
            XCTFail("親アルバム内の exact Reply track が見つからなかった")
            skippedScreens += playerScreens
            return
        }
        replyTrack.tap()

        // ミニプレイヤーの複合ラベルに曲名と操作を同時に要求し、検索結果や以前の再生状態を誤認しない。
        let openPlayer = app.buttons["Reply, Open Player"]
        let miniPlayerPause = app.buttons["miniplayer.play-pause"]
        guard openPlayer.waitForExistence(timeout: 40), miniPlayerPause.waitForExistence(timeout: 10),
            miniPlayerPause.label == "Pause", isRunning
        else {
            XCTFail("Reply のミニプレイヤーと一時停止状態を確認できなかった")
            skippedScreens += playerScreens
            return
        }
        guard openPlayer.exists else {
            XCTFail("Reply のミニプレイヤーを開けなかった")
            skippedScreens += playerScreens
            return
        }
        settle()
        capture("miniplayer")

        openPlayer.tap()
        let lyricsButton = element(.button, "歌詞")
        guard lyricsButton.waitForExistence(timeout: 10) else {
            XCTFail("Reply のフルプレイヤーが表示されなかった")
            skippedScreens += playerScreens.dropFirst()
            return
        }
        // 同名要素を総当たりすると XCUITest が稀に終了するため、プレイヤー側の固定 ID だけを検証する。
        let playerReplyTitle = app.staticTexts["nowplaying.title"]
        guard playerReplyTitle.waitForExistence(timeout: 10), playerReplyTitle.label == "Reply" else {
            XCTFail("フルプレイヤーのヘッダーが Reply ではなかった")
            skippedScreens += playerScreens.dropFirst()
            return
        }
        settle()
        capture("nowplaying")

        let playerPause = firstHittableElement(in: app.buttons.matching(identifier: "Pause"), timeout: 10)
        guard let playerPause else {
            XCTFail("Reply のフルプレイヤーを一時停止できなかった")
            skippedScreens += ["lyrics-loading", "lyrics", "queue"]
            return
        }
        playerPause.tap()
        lyricsButton.tap()
        // 通信中ではなく、同期歌詞を読み込んで先頭時刻より前に置いた安定状態を loading 参照へ使う。
        let introPlaceholder = app.staticTexts["lyrics.intro-placeholder"]
        let seekBar = app.otherElements.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
        ).firstMatch
        guard seekBar.waitForExistence(timeout: 10) else {
            XCTFail("Reply の再生位置を 0:00 に戻す slider が見つからなかった")
            skippedScreens += ["lyrics-loading", "lyrics", "queue"]
            return
        }
        var seekAttempts = 0
        while seekBar.value as? String != "0:00", seekAttempts < 3 {
            // SwiftUI の独自 adjustable 要素は XCUI の slider API を受けないため、
            // 実際のシークバー先頭へ短いドラッグを送り、アプリと同じ gesture 経路で戻す。
            let start = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let beginning = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: beginning)
            seekAttempts += 1
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        guard seekBar.value as? String == "0:00", introPlaceholder.waitForExistence(timeout: 20),
            introPlaceholder.isSelected, playerReplyTitle.exists
        else {
            XCTFail("Reply を 0:00 に置いた selected placeholder を表示できなかった")
            skippedScreens += ["lyrics-loading", "lyrics", "queue"]
            return
        }
        settle()
        capture("lyrics-loading")
        // 同期歌詞は行タップでシークできる Button として公開される。
        let lyricLine = app.buttons.matching(
            NSPredicate(format: "label == %@", "瞳映る 静かな世界 なにを見てたんだろう")
        ).firstMatch
        let unavailable = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Lyrics Not Available", "No Lyrics")
        ).firstMatch
        guard lyricLine.waitForExistence(timeout: 20), !unavailable.exists else {
            XCTFail("Reply の実歌詞が表示されなかった")
            skippedScreens += ["lyrics", "queue"]
            return
        }
        lyricLine.tap()
        let selectedLyric = expectation(
            for: NSPredicate(format: "isSelected == true"), evaluatedWith: lyricLine
        )
        guard XCTWaiter.wait(for: [selectedLyric], timeout: 5) == .completed else {
            XCTFail("Reply の既知行へシークして選択状態を確認できなかった")
            skippedScreens += ["lyrics", "queue"]
            return
        }
        XCTAssertTrue(playerReplyTitle.exists, "歌詞表示中の曲名が Reply ではない")
        settle()
        capture("lyrics")

        // 歌詞 2 枚を撮り終えてからだけ参照の 0:55 再生状態へ移し、歌詞 loading の前提を壊さない。
        let seekStart = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
        let queuePosition = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.2045, dy: 0.5))
        seekStart.press(forDuration: 0.05, thenDragTo: queuePosition)
        guard waitForSeekValue(seekBar, seconds: 55, tolerance: 2, timeout: 5) else {
            XCTFail("Queue 撮影前の Reply を約 0:55 へシークできなかった")
            skippedScreens.append("queue")
            return
        }
        let resume = firstHittableElement(in: app.buttons.matching(identifier: "Play"), timeout: 10)
        guard let resume else {
            XCTFail("Queue 撮影前に Reply を再開できなかった")
            skippedScreens.append("queue")
            return
        }
        resume.tap()
        element(.button, "次に再生").tap()

        let sharedTitle = app.staticTexts["nowplaying.title"]
        let upcomingRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "queue.upcoming."))
        let firstUpcoming = upcomingRows.element(boundBy: 0)
        let secondUpcoming = upcomingRows.element(boundBy: 1)
        guard sharedTitle.waitForExistence(timeout: 10), sharedTitle.label == "Reply",
            sharedTitle.value as? String == Self.replyItemID,
            firstUpcoming.waitForExistence(timeout: 10), secondUpcoming.waitForExistence(timeout: 10),
            firstUpcoming.identifier == "queue.upcoming.\(Self.rayItemID)",
            secondUpcoming.identifier == "queue.upcoming.\(Self.meltItemID)",
            firstUpcoming.label.localizedCaseInsensitiveContains("ray"),
            secondUpcoming.label.localizedCaseInsensitiveContains("Melt")
        else {
            XCTFail("Queue が exact Reply → Ray → Melt のアルバム順ではなかった")
            skippedScreens.append("queue")
            return
        }

        // Queue を開くまでの経過時間を捨て、撮影直前に参照の 0:55 へ置き直す。
        guard let pause = firstHittableElement(in: app.buttons.matching(identifier: "Pause"), timeout: 5)
        else {
            XCTFail("Queue 撮影前に再生中の Reply を一時停止できなかった")
            skippedScreens.append("queue")
            return
        }
        pause.tap()
        seekStart.press(forDuration: 0.05, thenDragTo: queuePosition)
        guard waitForSeekValue(seekBar, seconds: 55, tolerance: 2, timeout: 5) else {
            XCTFail("Queue を開いた後に Reply を約 0:55 へ再シークできなかった")
            skippedScreens.append("queue")
            return
        }
        guard let finalResume = firstHittableElement(in: app.buttons.matching(identifier: "Play"), timeout: 5)
        else {
            XCTFail("Queue 撮影直前に Reply を再開できなかった")
            skippedScreens.append("queue")
            return
        }
        finalResume.tap()

        let heading = app.staticTexts["queue.continue-playing"]
        let source = app.staticTexts["queue.source"]
        guard firstHittableElement(in: app.buttons.matching(identifier: "Pause"), timeout: 5) != nil,
            heading.exists, source.exists, source.label == "From Cosmic Princess Kaguya!"
        else {
            XCTFail("Queue 撮影に必要な再生状態・見出し・アルバム出典が揃わなかった")
            skippedScreens.append("queue")
            return
        }
        capture("queue")
    }

    /// ID を直接指定して Jellyfin item を照合する。撮影対象の親子関係を表示名から推測しない。
    private func apiItem(id: String) -> APISearchResult.Item? {
        guard let baseURL = URL(string: serverURL) else { return nil }
        let deviceID = UUID().uuidString
        let baseAuthorization =
            #"MediaBrowser Client="Musicfin", Device="iOS Simulator", DeviceId="\#(deviceID)", Version="0.1.0""#
        var authentication = URLRequest(url: baseURL.appending(path: "/Users/AuthenticateByName"))
        authentication.httpMethod = "POST"
        authentication.setValue(baseAuthorization, forHTTPHeaderField: "Authorization")
        authentication.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authentication.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        guard let (data, response) = synchronousData(for: authentication),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let session = try? JSONDecoder().decode(APIAuthentication.self, from: data)
        else { return nil }

        var components = URLComponents(url: baseURL.appending(path: "/Items"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "userId", value: session.user.id),
            URLQueryItem(name: "ids", value: id),
            URLQueryItem(name: "fields", value: "ParentId"),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(baseAuthorization + #", Token="\#(session.accessToken)""#, forHTTPHeaderField: "Authorization")
        guard let (itemData, itemResponse) = synchronousData(for: request),
            (itemResponse as? HTTPURLResponse)?.statusCode == 200,
            let result = try? JSONDecoder().decode(APISearchResult.self, from: itemData)
        else { return nil }
        return result.items.first
    }

    private func replyItem() -> APISearchResult.Item? {
        apiItem(id: Self.replyItemID)
    }

    private func apiSearch(query: String) -> APISearchResult? {
        guard let baseURL = URL(string: serverURL) else { return nil }
        let deviceID = UUID().uuidString
        let baseAuthorization =
            #"MediaBrowser Client="Musicfin", Device="iOS Simulator", DeviceId="\#(deviceID)", Version="0.1.0""#
        var authentication = URLRequest(url: baseURL.appending(path: "/Users/AuthenticateByName"))
        authentication.httpMethod = "POST"
        authentication.setValue(baseAuthorization, forHTTPHeaderField: "Authorization")
        authentication.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authentication.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        guard let (authenticationData, authenticationResponse) = synchronousData(for: authentication),
            (authenticationResponse as? HTTPURLResponse)?.statusCode == 200,
            let session = try? JSONDecoder().decode(APIAuthentication.self, from: authenticationData)
        else { return nil }

        var components = URLComponents(url: baseURL.appending(path: "/Items"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "userId", value: session.user.id),
            URLQueryItem(name: "fields", value: "PrimaryImageAspectRatio,ParentId,Genres,ChildCount"),
            URLQueryItem(name: "searchTerm", value: query),
            URLQueryItem(name: "includeItemTypes", value: "Audio,MusicAlbum,MusicArtist,Playlist"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "limit", value: "40"),
        ]
        guard let url = components?.url else { return nil }
        var search = URLRequest(url: url)
        search.setValue(baseAuthorization + #", Token="\#(session.accessToken)""#, forHTTPHeaderField: "Authorization")
        guard let (searchData, searchResponse) = synchronousData(for: search),
            (searchResponse as? HTTPURLResponse)?.statusCode == 200,
            let result = try? JSONDecoder().decode(APISearchResult.self, from: searchData)
        else { return nil }
        return result
    }

    /// XCTest の同期フローから API を照合するため、短い URLSession 処理だけを待つ。
    private func synchronousData(for request: URLRequest) -> (Data, URLResponse)? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output: (Data, URLResponse)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response { output = (data, response) }
            semaphore.signal()
        }.resume()
        return semaphore.wait(timeout: .now() + 20) == .success ? output : nil
    }

    /// Reply 撮影の成否にかかわらず sheet と検索語を片付け、後続の検索キャプチャを独立させる。
    @MainActor
    private func cleanupReplyCapture(searchField: XCUIElement) {
        if element(.button, "歌詞").exists {
            if isIPadCapture {
                app.swipeDown()
                _ = searchField.waitForExistence(timeout: 10)
            } else if !dismissSheet(revealing: searchField) {
                XCTFail("Reply のプレイヤーを閉じられなかった")
                return
            }
        }
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Reply 撮影後に検索欄へ戻れなかった")
            return
        }
        if isIPadCapture {
            // iPad はこの method の直後に app を破棄する。query は session 外へ永続化されないため、
            // player が閉じて Search root へ戻れたことを cleanup の完了条件にする。
            return
        }
        searchField.tap()
        let clear = app.buttons["Clear text"]
        if clear.waitForExistence(timeout: 2) {
            clear.tap()
        } else if searchFieldHasEnteredText(searchField) {
            // clear button が無い環境でも、選択範囲を全体へ固定してから一度だけ削除する。
            searchField.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            guard selectAll.waitForExistence(timeout: 2) else {
                XCTFail("Reply の検索語を全選択できなかった")
                return
            }
            selectAll.tap()
            searchField.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while ((searchField.value as? String) ?? "").contains("Reply"), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertFalse(((searchField.value as? String) ?? "").contains("Reply"), "Reply の検索語を消去できなかった")
        dismissKeyboard()
    }

    /// 渡された「再生」からアルバムを再生し、ミニプレイヤー → フルプレイヤー（アートワーク／歌詞／次に再生）を撮る。
    /// ストリーミングが始まらなければ 4 画面まとめてスキップし、後続の検索へ進む。
    @MainActor
    private func capturePlayerScreens(playButton: XCUIElement) {
        let playerScreens = ["miniplayer", "nowplaying", "lyrics-loading", "lyrics", "queue"]
        guard playButton.isEnabled else {
            skippedScreens += playerScreens
            return
        }
        playButton.tap()

        // 再生が始まるとミニプレイヤーの再生ボタンが「一時停止」になる。
        let pause = element(.button, "一時停止")
        guard pause.waitForExistence(timeout: 20), isRunning else {
            skippedScreens += playerScreens
            return
        }
        // ミニプレイヤーはタブバー付属のアクセサリなのでどのタブでも見える。アルバム詳細のまま撮る。
        let openPlayer = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
        guard openPlayer.waitForExistence(timeout: 10), isRunning else {
            skippedScreens += playerScreens
            return
        }
        settle()
        capture("miniplayer")

        openPlayer.tap()
        // 閉じるボタンは廃止された。下部のモード切替「歌詞」はどのモードでも常に出ていて
        // ミニプレイヤーにもブラウズ画面にも無いため、フルプレイヤー到達の判定に使える。
        let lyricsButton = element(.button, "歌詞")
        guard lyricsButton.waitForExistence(timeout: 10), isRunning else {
            skippedScreens += playerScreens.dropFirst()
            return
        }
        settle()
        capture("nowplaying")
        if isIPadCapture {
            capture("playing")
            return
        }

        guard isRunning else {
            skippedScreens += ["lyrics", "queue"]
            return
        }
        lyricsButton.tap()
        // 読み込み状態は一瞬で終わることがあるため、切替直後に先に残してから安定表示を撮る。
        capture("lyrics-loading")
        settle()
        capture("lyrics")

        guard isRunning else {
            skippedScreens.append("queue")
            return
        }
        element(.button, "次に再生").tap()
        settle()
        capture("queue")

        guard isRunning else { return }
        // 背後はアルバム詳細なので、その「再生」が再び押せるようになったら閉じたとみなす。
        if !dismissSheet(revealing: playButton) {
            skippedScreens.append("nowplaying-dismiss")
        }
    }

    /// sheet を下スワイプで閉じ、背後の要素が押せる状態に戻るまで待つ。
    /// 閉じられなくても無限に粘らず、呼び出し側が次へ進めるよう成否だけ返す。
    @MainActor
    private func dismissSheet(revealing target: XCUIElement, attempts maxAttempts: Int = 3) -> Bool {
        var attempts = 0
        while !target.isHittable, attempts < maxAttempts, isRunning {
            // sheet の上端を掴んで下まで引く。中央からの swipeDown では中身がスクロールするだけで閉じない。
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            start.press(forDuration: 0.05, thenDragTo: end)
            settle()
            attempts += 1
        }
        return target.isHittable
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
        let labels = ["ホーム": "Home", "ライブラリ": "Library", "検索": "Search"]
        let localizedTitle = labels[title] ?? title
        if isIPadCapture {
            let routeNames = ["ホーム": "home", "ライブラリ": "library", "検索": "search"]
            let sidebar = app.buttons["sidebar.\(routeNames[title] ?? title)"]
            guard sidebar.waitForExistence(timeout: 10) else {
                XCTFail("iPad sidebar を選べなかった: \(localizedTitle)")
                return
            }
            sidebar.tap()
            let selected = expectation(
                for: NSPredicate(format: "isSelected == true"), evaluatedWith: sidebar
            )
            _ = XCTWaiter.wait(for: [selected], timeout: 5)
            return
        }
        let tab = app.tabBars.buttons[localizedTitle]
        if !tab.exists {
            let closeSearch = app.tabBars.buttons["Close"]
            if closeSearch.exists { closeSearch.tap() }
        }
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
            return
        }
        // iPad sidebar は tab bar ではなく通常の Button なので、見えて操作できる同名行を選ぶ。
        if let sidebar = firstHittableElement(
            in: app.buttons.matching(identifier: localizedTitle), timeout: 5
        ) {
            sidebar.tap()
        } else {
            XCTFail("タブを選べなかった: \(localizedTitle)")
        }
    }

    // MARK: - 補助

    /// iPhone の tab search と iPad detail の searchable が公開する型差を吸収する。
    @MainActor
    private var searchFieldElement: XCUIElement {
        let search = app.searchFields.firstMatch
        if search.exists { return search }
        return app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@ OR placeholderValue == %@",
                "Artists, Songs, Lyrics, and More", "アーティスト、曲、歌詞など")
        ).firstMatch
    }

    /// 一覧の絞り込み欄。iPad は `librarySearchable` が `UISearchTextField` を自前で置くので
    /// `searchFields` には現れず、`app.searchFields.firstMatch` では掴めない（仕様 6 章）。
    @MainActor
    private var listSearchField: XCUIElement {
        let search = app.searchFields.firstMatch
        if search.exists { return search }
        return app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@ OR placeholderValue == %@", "Search", "検索")
        ).firstMatch
    }

    /// 検索欄の現在の入力。placeholder は value に混ざるので、その状態は空として返す。
    @MainActor
    private func enteredText(of field: XCUIElement) -> String {
        guard let value = field.value as? String, value != field.placeholderValue else { return "" }
        return value
    }

    /// 検索語を確実に入れる。1 文字目で入力前の画面が結果一覧へ切り替わると検索欄の focus が外れ、
    /// `typeText` の残りが丸ごと落ちる（実測では「Ray」が「R」になった）。
    /// 入力後の value を見て、足りない分だけ焦点を取り直して打ち足す。
    @MainActor
    @discardableResult
    private func typeSearchQuery(_ field: XCUIElement, _ query: String) -> Bool {
        for _ in 0..<query.count + 4 {
            let current = enteredText(of: field)
            if current == query { return true }
            guard query.hasPrefix(current) else {
                // 別の語が残っている状態から打ち足すと混ざるので、消してから入れ直す。
                field.tap()
                let clear = app.buttons["Clear text"]
                if clear.exists { clear.tap() }
                continue
            }
            field.tap()
            field.typeText(String(query.dropFirst(current.count)))
        }
        return enteredText(of: field) == query
    }

    /// 未入力時の `value` は空文字ではなく placeholder になるので、その状態を検索語と誤認しない。
    @MainActor
    private func searchFieldHasEnteredText(_ field: XCUIElement) -> Bool {
        guard let value = field.value as? String else { return false }
        return !value.isEmpty
            && value != "Artists, Songs, Lyrics, and More"
            && value != "アーティスト、曲、歌詞など"
    }

    /// シークバーが公開する m:ss を秒へ戻し、参照時刻へ着地したことを待つ。
    @MainActor
    private func waitForSeekValue(
        _ element: XCUIElement, seconds: Int, tolerance: Int, timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let value = element.value as? String {
                let parts = value.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2, abs(parts[0] * 60 + parts[1] - seconds) <= tolerance {
                    return true
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        return false
    }

    /// query の中から実際に操作可能な要素を探す。背後に残る同名要素を誤認しないために使う。
    @MainActor
    private func firstHittableElement(in query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            for index in 0..<query.count {
                let candidate = query.element(boundBy: index)
                if candidate.exists, candidate.isHittable { return candidate }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return nil
    }

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

    /// 要素が消えるまで待つ。同じ文言のボタンが遷移元にもある画面で、遷移の成否を確かめるのに使う。
    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return !element.exists
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
        let tutorialContinue = element(.button, "Continue")
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
        guard app.keyboards.firstMatch.exists else { return }
        // 検索結果の一覧は interactive dismiss に応じないので、閉じられないまま結果の下半分が
        // キーボードに隠れる。iPad のソフトキーボード右下にある格納キーなら確実に閉じられる。
        let hide = app.keyboards.buttons.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "hide keyboard",
                "キーボードを閉じる")
        ).firstMatch
        if hide.exists {
            hide.tap()
            settle()
        }
    }

    /// 遷移アニメーションが終わるのを待ってから撮る。
    @MainActor
    private func settle() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
    }

    /// 結果バンドルへの添付と、比較しやすいようファイルへの書き出しを両方行う。ファイル名は `<画面>.png`。
    @MainActor
    private func capture(_ screen: String) {
        let fileName = "\(screen).png"
        guard let shotDirectory, let bridge = captureBridgeDirectory else {
            XCTFail("screenshot または capture bridge の保存先が設定されていない")
            return
        }
        do {
            try FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
            let request = bridge.appendingPathComponent("\(screen).request")
            let pending = bridge.appendingPathComponent(".\(screen).request.tmp")
            let ack = bridge.appendingPathComponent("\(screen).ack")
            let failure = bridge.appendingPathComponent("\(screen).error")
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: ack)
            try? FileManager.default.removeItem(at: failure)
            try screen.data(using: .utf8)?.write(to: pending)
            try FileManager.default.moveItem(at: pending, to: request)

            // native framebuffer が保存されるまで現在の semantic 状態を保持する。
            let deadline = Date(timeIntervalSinceNow: 20)
            while !FileManager.default.fileExists(atPath: ack.path),
                !FileManager.default.fileExists(atPath: failure.path), Date() < deadline
            {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            if FileManager.default.fileExists(atPath: failure.path) {
                let detail = try String(contentsOf: failure, encoding: .utf8)
                XCTFail("native screenshot worker が失敗した: \(fileName) — \(detail)")
                return
            }
            guard FileManager.default.fileExists(atPath: ack.path) else {
                XCTFail("native screenshot worker が timeout した: \(fileName)")
                return
            }
            let output = shotDirectory.appendingPathComponent(fileName)
            let png = try Data(contentsOf: output)
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = fileName
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("native screenshot を受け取れなかった: \(fileName) — \(error)")
            return
        }
        capturedNames.insert(screen)
    }
}
