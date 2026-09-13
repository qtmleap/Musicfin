import XCTest

/// 主要画面を同じ手順で撮影し、`docs/screenshots/manifest.json`（スクリプトが生成）経由で比較できるようにする。
/// 保存先は `MUSICFIN_SHOT_DIR` で受け取る。
/// 文字サイズは `MUSICFIN_CONTENT_SIZE` で受け取る（例 `UICTContentSizeCategoryAccessibilityXXXL`）。
/// 未指定なら Simulator の既定サイズのままにする。
/// アプリ本体に `accessibilityIdentifier` を足さず、表示ラベルだけで操作する。
final class CaptureScreensUITests: XCTestCase {
    private static let demoServerURL = "https://demo.jellyfin.org/stable"
    private static let demoUser = "demo"

    // XCUIApplication は MainActor 隔離なので、テスト本体と補助メソッドを MainActor に置く。
    // クラス自体を MainActor にすると XCTestCase の nonisolated な override と衝突する。
    private var app: XCUIApplication!
    private var shotDirectory: URL?
    /// `UICTContentSizeCategory…` の名前をそのまま持つ。未指定なら nil。
    private var contentSizeCategory: String?
    private var capturedNames: Set<String> = []
    private var skippedScreens: [String] = []

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

        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["MUSICFIN_SHOT_DIR"], !directory.isEmpty {
            shotDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        }
        if let category = environment["MUSICFIN_CONTENT_SIZE"], !category.isEmpty {
            contentSizeCategory = category
        }
    }

    @MainActor
    private func launchApp() {
        app = XCUIApplication()
        app.launchEnvironment["MUSICFIN_SHOT_DIR"] = shotDirectory?.path ?? ""
        // 文字サイズは起動引数でしか差し替えられない（Simulator 全体の設定を触らずに済む）。
        // 未指定のときは引数ごと足さないので、既定の撮影は今までと同じ経路を通る。
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
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
        username.typeText(Self.demoUser)

        let signIn = element(.button, "ログイン")
        tapScrollingIntoView(signIn)
    }

    // MARK: - ログイン後の画面

    @MainActor
    func testCaptureAppScreens() throws {
        launchApp()
        ensureSignedIn()

        // ホーム: セクションが出るまで待って読込完了とみなす。
        let recentlyAdded = element(.staticText, "最近追加したアルバム")
        let account = element(.button, "アカウント")
        XCTAssertTrue(
            waitForAny([recentlyAdded, account], timeout: 30),
            "ホームが表示されなかった"
        )
        settle()
        capture("home")

        // ライブラリ → アルバム一覧 → 先頭のアルバム詳細。
        selectTab("ライブラリ")
        XCTAssertTrue(element(.staticText, "ライブラリ").firstMatch.waitForExistence(timeout: 10), "ライブラリが表示されなかった")
        settle()
        capture("library")

        // ライブラリ配下の遷移先。ライブラリ本体と同じ平坦なリストに見えるかを比較できるよう 1 枚ずつ撮る。
        captureLibraryChild(
            row: "アーティスト", title: "アーティスト", screen: "artists", dependents: ["artist"]
        ) {
            self.captureArtistDetail()
        }
        captureLibraryChild(
            row: "プレイリスト", title: "プレイリスト", screen: "playlists", dependents: ["playlist"]
        ) {
            self.capturePlaylistDetail()
        }
        captureLibraryChild(row: "ジャンル", title: "ジャンル", screen: "genres")
        captureLibraryChild(row: "曲", title: "曲", screen: "songs")
        captureLibraryChild(row: "お気に入りの曲", title: "お気に入りの曲", screen: "favorites")

        app.buttons["library.albums"].tap()
        // 位置で引くと一覧の先頭にある「再生」を掴んでしまい、詳細ではなく一覧が撮れる。
        let firstAlbum = app.buttons["album.card"].firstMatch
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 20), "アルバムが 1 件も読み込まれなかった")
        settle()
        capture("albums")

        // 曲行が 2 行以上あるアルバムを開く。1 行しか写らないと、トラック番号の出方も
        // ディスク→番号の並び順も比べる相手がいない（仕様 7.3 章）。
        // 見つからないときは先頭のアルバムが開いた状態で返るので、今までどおり撮って先へ進む。
        let play = openAlbum(minimumTracks: 2) ?? element(.button, "再生")
        XCTAssertTrue(play.waitForExistence(timeout: 20), "アルバム詳細が表示されなかった")
        // 再生中の行に出るイコライザは鳴らさないと写らないので、1 曲目を再生してから撮る（仕様 2 章）。
        let firstTrack = app.buttons["album.track"].firstMatch
        if firstTrack.waitForExistence(timeout: 20) {
            firstTrack.tap()
            // ミニプレイヤーが出るまで待つ。先に撮ると行の色も棒も再生前のままになる。
            XCTAssertTrue(element(.button, "一時停止").waitForExistence(timeout: 40), "再生が始まらず album を再生中で撮れない")
        } else {
            XCTFail("アルバムの曲行が見つからず、album を再生中で撮れない")
        }
        settle()
        capture("album")

        // `album` は 1 曲のアルバムのまま残し、再生だけ 2 曲以上のアルバムから始める。
        // 先頭のアルバムで再生すると待機曲が 0 件になり、`queue` が空状態しか撮れない（仕様 5.2 章）。
        let playbackPlay = openAlbumWithUpcomingTracks() ?? play
        capturePlayerScreens(playButton: playbackPlay)
        recoverIfTerminated()
        // sheet が残っているとタブバーに触れず検索へ進めない。念のためもう一度閉じる。
        if element(.button, "歌詞").exists {
            _ = dismissSheet(revealing: play)
        }

        // 検索: 入力前の状態を撮ってから、クエリを入れて結果の行が出るまで待つ。
        selectTab("検索")
        let searchField = app.searchFields.firstMatch
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
        let card = app.buttons["album.card"].firstMatch
        let empty = element(.staticText, "アルバムがありません")
        // 一覧に見えている範囲だけ試す。全件当たっても見つからないなら撮影データ側の問題なので落とす。
        for index in 0..<min(artists.count, 8) {
            let artist = artists.element(boundBy: index)
            guard artist.exists else { break }
            artist.tap()

            // 詳細の navigationTitle はアーティスト名で事前に分からないので、戻るボタンの文字で到達を判定する。
            let back = app.navigationBars.buttons["Artists"]
            guard back.waitForExistence(timeout: 20) else {
                skippedScreens.append("artist")
                return
            }
            // 読込中は空と見分けが付かないので、グリッドか「アルバムがありません」のどちらかが出るまで待つ。
            _ = waitForAny([card, empty], timeout: 20)
            if card.exists {
                settle()
                capture("artist")
                return
            }
            back.tap()
            _ = artists.firstMatch.waitForExistence(timeout: 10)
        }
        XCTFail("アルバムを持つアーティストが見つからず、artist 画面を撮れなかった")
        skippedScreens.append("artist")
    }

    /// プレイリスト一覧の先頭を開いて詳細を撮る。戻りは `goBackToLibrary` の多段 pop に任せる。
    /// `continueAfterFailure` が true なので、待てなかったときは `XCTFail` だけでは止まらない。
    /// 0 件・0 曲の画面を代用として残さないよう、どの失敗も `guard` で必ず抜ける。
    @MainActor
    private func capturePlaylistDetail() {
        let row = app.buttons["playlist.row"].firstMatch
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
        guard app.buttons["playlist.track"].firstMatch.waitForExistence(timeout: 20) else {
            XCTFail("プレイリストの曲が 1 件も出ず、playlist 画面を撮れなかった")
            skippedScreens.append("playlist")
            return
        }
        settle()
        // ここで再生を始めると後続のアルバム・プレイヤー撮影の状態が変わるので、撮るだけで戻る。
        capture("playlist")
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
        let cards = app.buttons.matching(identifier: "album.card")
        // 先頭も候補に入れる。1 曲だと分かっていても、決め打ちにすると撮影データが変わったとき黙ってずれる。
        for index in 0..<min(cards.count, maxAlbums) {
            let card = cards.element(boundBy: index)
            guard card.exists else { break }
            card.tap()
            if let play = waitForLoadedAlbumDetail(),
                app.buttons.matching(identifier: "album.track").count >= minimumTracks
            {
                return play
            }
            guard goBackToAlbums() else { return nil }
        }

        let first = app.buttons["album.card"].firstMatch
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
        let play = element(.button, "再生")
        guard play.waitForExistence(timeout: 10) else { return nil }
        _ = XCTWaiter.wait(
            for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: play)],
            timeout: 20)
        return play.isEnabled ? play : nil
    }

    /// アルバム詳細からアルバム一覧へ戻す。既に一覧なら何もしない。
    @MainActor
    private func goBackToAlbums() -> Bool {
        let cards = app.buttons["album.card"].firstMatch
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
        guard app.buttons["album.card"].firstMatch.waitForExistence(timeout: 20) else {
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
            guard back.exists else { break }
            back.tap()
            attempts += 1
            settle()
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

    /// 渡された「再生」からアルバムを再生し、ミニプレイヤー → フルプレイヤー（アートワーク／歌詞／次に再生）を撮る。
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

        guard isRunning else {
            skippedScreens += ["lyrics", "queue"]
            return
        }
        lyricsButton.tap()
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
        let tab = app.tabBars.buttons[localizedTitle]
        if !tab.exists {
            let closeSearch = app.tabBars.buttons["Close"]
            if closeSearch.exists { closeSearch.tap() }
        }
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        } else {
            app.buttons[localizedTitle].firstMatch.tap()
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
