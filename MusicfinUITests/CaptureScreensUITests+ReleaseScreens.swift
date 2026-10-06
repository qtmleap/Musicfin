import Foundation
import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testCaptureReleaseScreens() throws {
        // 一部だけ成功した画像をリリース用の一式として扱わないため、最初の失敗で止める。
        continueAfterFailure = false
        let configuration = try ReleaseCaptureConfiguration()
        if isIPadCapture { try configureReleaseIPadFullScreen() }
        try launchReleaseApp(configuration)
        if isIPadCapture {
            let window = app.windows.firstMatch
            try requireReleaseState(window.frame.height > window.frame.width, "iPadのウインドウが縦向きではなかった")
        }
        try signInToReleaseDemo(configuration)

        let homeTitle = app.staticTexts[configuration.label("ホーム", "Home")].firstMatch
        try requireReleaseState(
            homeTitle.waitForExistence(timeout: 20),
            "ホームの表示言語が指定と一致しない: \(configuration.locale)\n\(app.debugDescription)")
        let homeAlbum = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@",
                "home.top-pick.", "home.top-pick.favorites")
        ).firstMatch
        try requireReleaseState(homeAlbum.waitForExistence(timeout: 40), "ホームの実在アルバムが読み込まれなかった")
        let recommendation = app.buttons["home.top-pick.\(configuration.albumID)"]
        try requireReleaseState(recommendation.waitForExistence(timeout: 20), "画像付きのデモアルバムがホームに現れなかった")
        // デモの先頭作品は画像未登録なので、実際の横送りで画像のある作品を先頭に見せる。
        let distance = recommendation.frame.minX - homeAlbum.frame.minX
        if distance > 10 {
            let start = recommendation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = start.withOffset(CGVector(dx: -distance, dy: 0))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        try captureReleaseScreen("01-home")
        if ProcessInfo.processInfo.environment["MUSICFIN_RELEASE_HOME_ONLY"] == "1" { return }

        try openReleaseLibraryRoute("albums", configuration: configuration)
        let album = app.buttons["album.card.\(configuration.albumID)"]
        try requireReleaseState(album.waitForExistence(timeout: 40), "指定したデモアルバムが一覧に表示されなかった")
        try captureReleaseScreen("02-albums")
        try tapReleaseElement(album, message: "指定したデモアルバムを開けなかった")

        let albumTitle = app.staticTexts["album.detail"]
        let albumTrack = app.buttons["album.track.\(configuration.trackID)"]
        let albumPlay = app.buttons["album.play"].firstMatch
        try requireReleaseState(albumTitle.waitForExistence(timeout: 20), "アルバム詳細へ遷移しなかった")
        try requireReleaseState(albumTitle.label == configuration.albumTitle, "アルバム詳細の題名が指定と一致しない")
        try requireReleaseState(albumTrack.waitForExistence(timeout: 30), "指定したJellyfinの曲がアルバム詳細に現れなかった")
        try requireReleaseState(
            albumPlay.waitForExistence(timeout: 10) && waitForReleaseState(timeout: 20) { albumPlay.isEnabled },
            "アルバムの収録曲が読み込み終わらなかった")
        try captureReleaseScreen("03-album-detail")

        // Nemesis は 1 曲だけなので、全曲一覧の実際の曲順から再生し、空のキューを撮らない。
        try openReleaseLibraryRoute("songs", configuration: configuration)
        let song = app.buttons.matching(identifier: "song.row").matching(
            NSPredicate(format: "label CONTAINS %@", configuration.trackTitle)
        ).firstMatch
        var retriedSongs = false
        let songsReady = waitForReleaseState(timeout: 40) {
            if song.exists { return true }
            let retry = app.buttons[configuration.label("再試行", "Try Again")].firstMatch
            // 詳細から一覧へ切り替えると要求が取消される場合があるため、実際の再試行操作で回復させる。
            if !retriedSongs, retry.exists, retry.isHittable {
                retry.tap()
                retriedSongs = true
            }
            return false
        }
        try requireReleaseState(songsReady, "全曲一覧にJellyfinが表示されなかった")
        try settleReleaseContent()
        try tapReleaseElement(song, message: "全曲一覧のJellyfinを再生できなかった")

        let miniPlayerPause = app.buttons["miniplayer.play-pause"]
        try requireReleaseState(miniPlayerPause.waitForExistence(timeout: 40), "実際のミニプレイヤーが現れなかった")
        try requireReleaseState(
            waitForReleaseState(timeout: 40) {
                miniPlayerPause.label == configuration.label("一時停止", "Pause")
            }, "Jellyfinの再生が開始しなかった")
        let openPlayer = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND (label ENDSWITH %@ OR label ENDSWITH %@)",
                configuration.trackTitle, "Open Player", "プレイヤーを開く")
        ).firstMatch
        try tapReleaseElement(openPlayer, message: "Jellyfinのミニプレイヤーを開けなかった")

        let playingTitle = app.staticTexts["nowplaying.title"]
        try requireReleaseState(playingTitle.waitForExistence(timeout: 20), "再生中画面の曲名が現れなかった")
        try requireReleaseState(playingTitle.label == configuration.trackTitle, "再生中の曲がJellyfinではなかった")
        let seek = app.otherElements.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
        ).firstMatch
        try requireReleaseState(seek.waitForExistence(timeout: 10), "実際の再生位置が表示されなかった")
        try requireReleaseState(
            waitForReleaseState(timeout: 45) { releasePlaybackSeconds(seek) > 0 },
            "デモサーバーの音声が再生されなかった")
        try captureReleaseScreen("04-now-playing")

        let queueButton = app.buttons[configuration.label("次に再生", "Play Next")].firstMatch
        try tapReleaseElement(queueButton, message: "再生中画面のキューを開けなかった")
        let upcoming = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "queue.upcoming.")
        ).firstMatch
        try requireReleaseState(upcoming.waitForExistence(timeout: 20), "キューに実在する次の曲が現れなかった")
        try requireReleaseState(playingTitle.label == configuration.trackTitle, "キュー撮影前に曲が切り替わった")
        try captureReleaseScreen("05-queue")

        // キューを畳んでから閉じると、List のスクロールが終了用のドラッグを奪わない。
        try tapReleaseElement(queueButton, message: "キューからアートワークへ戻れなかった")
        try requireReleaseState(waitForDisappearance(of: upcoming, timeout: 10), "キューを閉じられなかった")
        try dismissReleasePlayer(playingTitle)
        try selectReleaseDestination("search", configuration: configuration)

        let search = searchFieldElement
        try requireReleaseState(search.waitForExistence(timeout: 15), "検索欄が現れなかった")
        try tapReleaseElement(search, message: "検索欄を操作できなかった")
        dismissReleaseKeyboardTutorial()
        try requireReleaseState(typeSearchQuery(search, configuration.searchQuery), "指定した検索語を入力できなかった")
        // 入力だけで検索が走り、iPad は結果の更新でフォーカスが外れるため、追加の Return を送らない。
        if !isIPadCapture { search.typeText("\n") }
        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "search.result.")
        ).firstMatch
        try requireReleaseState(result.waitForExistence(timeout: 30), "デモサーバーの検索結果が現れなかった")
        try hideReleaseSearchKeyboard()
        try requireReleaseState(enteredText(of: search) == configuration.searchQuery, "撮影前に検索語が変わった")
        try captureReleaseScreen("06-search")
        try requireReleaseState(capturedNames.count == 6, "リリース用の6画面が揃わなかった")
    }

    private struct ReleaseCaptureConfiguration {
        let locale: String
        let serverURL: String
        let albumID: String
        let albumTitle: String
        let trackID: String
        let searchQuery: String
        let trackTitle = "Jellyfin"

        var language: String { locale == "ja" ? "ja" : "en" }
        var appleLocale: String { locale == "ja" ? "ja_JP" : "en_US" }

        init() throws {
            let environment = ProcessInfo.processInfo.environment
            locale = try XCTUnwrap(environment["MUSICFIN_RELEASE_LOCALE"], "撮影ロケールが指定されていない")
            guard ["ja", "en-US"].contains(locale) else {
                throw ReleaseCaptureFailure.invalidState("未対応の撮影ロケール")
            }
            serverURL = environment["MUSICFIN_SERVER_URL"] ?? "https://demo.jellyfin.org/stable"
            guard
                serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://demo.jellyfin.org/stable",
                (environment["MUSICFIN_USERNAME"] ?? "demo") == "demo",
                (environment["MUSICFIN_PASSWORD"] ?? "").isEmpty
            else {
                throw ReleaseCaptureFailure.invalidState("リリース撮影は公式デモと空パスワードのdemoアカウントに限定する")
            }
            albumID = try XCTUnwrap(environment["MUSICFIN_RELEASE_ALBUM_ID"], "解決済みのアルバムIDが指定されていない")
            albumTitle = environment["MUSICFIN_RELEASE_ALBUM_TITLE"] ?? "Nemesis"
            trackID = try XCTUnwrap(environment["MUSICFIN_RELEASE_TRACK_ID"], "解決済みの曲IDが指定されていない")
            searchQuery = environment["MUSICFIN_RELEASE_SEARCH_QUERY"] ?? "Binärpilot"
            guard !albumID.isEmpty, !trackID.isEmpty, !albumTitle.isEmpty, !searchQuery.isEmpty else {
                throw ReleaseCaptureFailure.invalidState("デモの撮影対象が空になっている")
            }
        }

        func label(_ japanese: String, _ english: String) -> String {
            locale == "ja" ? japanese : english
        }
    }

    private enum ReleaseCaptureFailure: Error {
        case invalidState(String)
    }

    @MainActor
    private func configureReleaseIPadFullScreen() throws {
        // マルチタスクのウインドウ枠を提出画像へ含めないため、新規 iPad の全画面設定を揃える。
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        let multitasking = settings.staticTexts["Multitasking & Gestures"].firstMatch
        for _ in 0..<6 {
            if multitasking.exists && multitasking.isHittable { break }
            let start = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8))
            let end = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.3))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        try requireReleaseState(
            multitasking.waitForExistence(timeout: 10) && multitasking.isHittable,
            "iPadのマルチタスク設定が見つからなかった\n\(settings.debugDescription)")
        multitasking.tap()
        let fullScreen = settings.descendants(matching: .any).matching(identifier: "Full Screen Apps").firstMatch
        try requireReleaseState(
            fullScreen.waitForExistence(timeout: 10) && fullScreen.isHittable,
            "iPadの全画面設定が見つからなかった\n\(settings.debugDescription)")
        fullScreen.tap()
        let selected = settings.buttons["com.apple.settings.multitaskingAndGestures.fullScreenApps"]
        try requireReleaseState(
            waitForReleaseState(timeout: 10) { selected.isSelected },
            "iPadの全画面設定が選択されなかった")
        // 選択直後に設定を終了するとウインドウ設定の反映が間に合わず、回転だけが無視される。
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
        settings.terminate()
    }

    @MainActor
    private func launchReleaseApp(_ configuration: ReleaseCaptureConfiguration) throws {
        app = XCUIApplication()
        // 既存の比較撮影の英語固定と空プレイヤーの起動条件を引き継がない。
        app.launchArguments = [
            "-AppleLanguages", "(\(configuration.language))", "-AppleLocale", configuration.appleLocale,
        ]
        app.launchEnvironment["AppleLanguages"] = "(\(configuration.language))"
        app.launchEnvironment["AppleLocale"] = configuration.appleLocale
        app.launchEnvironment["MUSICFIN_CAPTURE_PLAYER"] = "0"
        app.launch()
        try requireReleaseState(app.windows.firstMatch.waitForExistence(timeout: 15), "アプリのウインドウが現れなかった")
    }

    @MainActor
    private func signInToReleaseDemo(_ configuration: ReleaseCaptureConfiguration) throws {
        let connect = app.buttons[configuration.label("接続", "Connect")]
        // 保存済みセッションへ進むと別サーバーの内容を公開し得るので、新規ログインだけを許す。
        try requireReleaseState(
            connect.waitForExistence(timeout: 20),
            "指定言語の新規サーバー入力画面が必要: \(configuration.locale)\n\(app.debugDescription)")
        let server = app.textFields.firstMatch
        try requireReleaseState(server.waitForExistence(timeout: 5), "サーバーURLの入力欄が現れなかった")
        try requireReleaseState(enteredText(of: server).isEmpty, "新しいSimulatorの空のサーバー入力欄が必要")
        try tapReleaseElement(server, message: "サーバーURLを入力できなかった")
        dismissReleaseKeyboardTutorial()
        server.typeText(configuration.serverURL)
        try tapReleaseElement(connect, message: "公式デモへの接続を開始できなかった")

        let changeServer = app.buttons[configuration.label("サーバーを変更", "Change Server")]
        try requireReleaseState(changeServer.waitForExistence(timeout: 30), "公式デモへの接続が完了しなかった")
        let username = app.textFields[configuration.label("ユーザー名", "Username")]
        try tapReleaseElement(username, message: "ユーザー名の入力欄が現れなかった")
        dismissReleaseKeyboardTutorial()
        username.typeText("demo")
        let signIn = app.buttons[configuration.label("ログイン", "Sign In")]
        try tapReleaseElement(signIn, scrollIfNeeded: true, message: "空パスワードでのログインを開始できなかった")
        let account = app.buttons[configuration.label("アカウント", "Account")].firstMatch
        try requireReleaseState(account.waitForExistence(timeout: 40), "公式デモへのログインが完了しなかった")
    }

    @MainActor
    private func openReleaseLibraryRoute(_ route: String, configuration: ReleaseCaptureConfiguration) throws {
        if isIPadCapture {
            try selectReleaseDestination(route, configuration: configuration)
            return
        }
        try selectReleaseDestination("library", configuration: configuration)
        let libraryAccount = app.buttons["library.account"]
        for _ in 0..<4 {
            if libraryAccount.exists { break }
            let back = app.navigationBars.buttons.firstMatch
            try tapReleaseElement(back, message: "ライブラリの入口へ戻れなかった")
            settle()
        }
        try requireReleaseState(libraryAccount.waitForExistence(timeout: 10), "ライブラリの入口が現れなかった")
        try tapReleaseElement(app.buttons["library.\(route)"], message: "ライブラリの\(route)を開けなかった")
    }

    @MainActor
    private func selectReleaseDestination(_ route: String, configuration: ReleaseCaptureConfiguration) throws {
        if isIPadCapture {
            let sidebar = padSidebarRow("sidebar.\(route)")
            try tapReleaseElement(sidebar, message: "iPadの\(route)を選択できなかった")
            try requireReleaseState(waitForReleaseState(timeout: 10) { sidebar.isSelected }, "iPadの選択先が変わらなかった")
            return
        }
        let labels = [
            "home": configuration.label("ホーム", "Home"),
            "library": configuration.label("ライブラリ", "Library"),
            "search": configuration.label("検索", "Search"),
        ]
        let title = try XCTUnwrap(labels[route], "未知の撮影タブ")
        try tapReleaseElement(app.tabBars.buttons[title], message: "\(route)タブを選べなかった")
    }

    @MainActor
    private func dismissReleasePlayer(_ title: XCUIElement) throws {
        for _ in 0..<3 {
            if !title.exists { return }
            // iPad の終了操作は上端 44 pt にあるため、本文やアートワークを掴まない。
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: isIPadCapture ? 0.025 : 0.08))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            start.press(forDuration: 0.1, thenDragTo: end)
            _ = waitForDisappearance(of: title, timeout: 5)
        }
        try requireReleaseState(!title.exists, "再生中画面を閉じられなかった")
    }

    @MainActor
    private func dismissReleaseKeyboardTutorial() {
        let tutorial = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Continue", "続ける"))
            .firstMatch
        if tutorial.waitForExistence(timeout: 1) { tutorial.tap() }
    }

    @MainActor
    private func hideReleaseSearchKeyboard() throws {
        guard app.keyboards.firstMatch.exists else { return }
        let hide = app.keyboards.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "hide keyboard", "キーボードを閉じる")
        ).firstMatch
        if hide.exists { hide.tap() }
        if app.keyboards.firstMatch.exists {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.25))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.9))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        try requireReleaseState(
            waitForDisappearance(of: app.keyboards.firstMatch, timeout: 10), "検索結果を覆うキーボードを閉じられなかった")
    }

    @MainActor
    private func tapReleaseElement(_ element: XCUIElement, scrollIfNeeded: Bool = false, message: String) throws {
        try requireReleaseState(element.waitForExistence(timeout: 15), message)
        if scrollIfNeeded {
            for _ in 0..<4 {
                if element.isHittable { break }
                app.swipeUp()
            }
        }
        try requireReleaseState(waitForReleaseState(timeout: 10) { element.isHittable }, message)
        element.tap()
    }

    @MainActor
    private func captureReleaseScreen(_ name: String) throws {
        try settleReleaseContent()
        capture(name)
        try requireReleaseState(capturedNames.contains(name), "native screenshotを保存できなかった: \(name)")
    }

    @MainActor
    private func settleReleaseContent() throws {
        try requireReleaseState(
            waitForReleaseState(timeout: 40) {
                app.activityIndicators.allElementsBoundByIndex.allSatisfy { !$0.isHittable }
            }, "読み込み中の表示が残っている")
        // アートワークには読込完了の識別子が無いため、データの出現後にも画像と背景の遷移を待つ。
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 4))
        try requireReleaseState(app.state == .runningForeground, "撮影前にアプリが終了した")
        try requireReleaseState(!app.keyboards.firstMatch.exists, "撮影前にキーボードが残っている")
    }

    @MainActor
    private func releasePlaybackSeconds(_ seek: XCUIElement) -> Int {
        guard let value = seek.value as? String else { return 0 }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    @MainActor
    private func waitForReleaseState(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return condition()
    }

    @MainActor
    private func requireReleaseState(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw ReleaseCaptureFailure.invalidState(message()) }
    }
}
