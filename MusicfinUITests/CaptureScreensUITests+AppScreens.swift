import Foundation
import XCTest

extension CaptureScreensUITests {
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
            padSidebarRow("sidebar.albums").tap()
            // iPhone 側は `captureLibraryChild` が走査を待つが、sidebar 経由はそこを通らない。
            // 全アルバムの走査中にグリッドを待ち始めると、カードが並ぶ前に待ち時間を使い切る。
            waitForCatalogScan()
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
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 30), "アルバムが 1 件も読み込まれなかった")
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

        // プレイヤーの対話的終了は閉じ切れないことがあり、閉じ残すと検索欄が編集中のまま残って
        // ジャンル一覧の代わりに空の結果が出る。iPad の Search と同じく新しい scene のルートから
        // 始めて、前の画面の状態を検索の撮影へ持ち込まない。
        launchApp()
        ensureSignedIn()

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
    func openCosmicAlbum() -> XCUIElement? {
        guard let parentID = replyItem()?.parentID, parentID == Self.cosmicAlbumID else {
            XCTFail("Reply の親アルバム ID が参照作品と一致しなかった")
            return nil
        }
        let albumCard = app.buttons["album.card.\(Self.cosmicAlbumID)"]
        if !albumCard.exists {
            if isIPadCapture {
                padSidebarRow("sidebar.albums").tap()
            } else if app.buttons["library.account"].exists {
                app.buttons["library.albums"].tap()
            }
            // 検索タブ（role: .search）から来た場合はタブバーが折り畳まれておりここでは
            // Library へ遷移できないため、何もせず後続の exact ID 検索フォールバックに任せる。
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
}
