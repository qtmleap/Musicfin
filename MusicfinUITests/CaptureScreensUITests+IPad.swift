import Foundation
import XCTest

// MARK: - ログイン後の画面

extension CaptureScreensUITests {
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

        padSidebarRow("sidebar.search").tap()
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
        padSidebarRow("sidebar.albums").tap()
        let firstAlbum = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "album.card.")
        ).firstMatch
        XCTAssertTrue(firstAlbum.waitForExistence(timeout: 30), "アルバムが 1 件も読み込まれなかった")
        settle()
        capture("albums")
    }

    /// 板が閉じられないこと、表示モードボタンが出ないことの確認（仕様 6 章）。
    /// 静止画では見えない要件なので、実際に払って板の位置と幅が動かないことで確かめる。
    @MainActor
    func testPadSidebarCannotBeDismissed() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp()
        ensureSignedIn()

        let albums = padSidebarRow("sidebar.albums")
        XCTAssertTrue(albums.waitForExistence(timeout: 30), "sidebar が表示されなかった")
        let before = albums.frame
        XCTAssertLessThan(before.maxX, 280, "sidebar の行が板の幅に収まっていない: \(before)")

        let toggles = app.descendants(matching: .button).matching(
            NSPredicate(format: "identifier == %@ OR label CONTAINS[c] %@", "ToggleSidebar", "sidebar")
        )
        XCTAssertEqual(
            toggles.count, 0,
            "sidebar toggle が残っている: \(toggles.allElementsBoundByIndex.map(\.label))")

        let window = app.windows.firstMatch
        func drag(_ fromX: CGFloat, _ toX: CGFloat, _ what: String) {
            let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            origin.withOffset(CGVector(dx: fromX, dy: 512))
                .press(
                    forDuration: 0.1,
                    thenDragTo: origin.withOffset(CGVector(dx: toX, dy: 512)))
            settle()
            XCTAssertTrue(albums.exists, "\(what) の後に sidebar が消えた")
            XCTAssertEqual(
                albums.frame.minX, before.minX, accuracy: 0.5, "\(what) で板が動いた")
            XCTAssertEqual(
                albums.frame.maxX, before.maxX, accuracy: 0.5, "\(what) で板の幅が変わった")
        }
        albums.swipeLeft()
        settle()
        XCTAssertEqual(albums.frame.minX, before.minX, accuracy: 0.5, "行の上で素早く左へ払ったら動いた")
        window.swipeRight()
        settle()
        XCTAssertEqual(albums.frame.minX, before.minX, accuracy: 0.5, "窓の上で素早く右へ払ったら動いた")
        // 板と detail の開始位置は画素ではなく要素の枠でも確かめる（仕様 6 章）。
        let account = app.buttons["sidebar.account"]
        // 仕様 6 章の 10 pt / 269.5 pt。UI test は app と型を共有しないので数値を直に書く。
        XCTAssertEqual(account.frame.minX, 10, accuracy: 0.5, "板の左端が 10 pt でない")
        XCTAssertEqual(account.frame.width, 269.5, accuracy: 0.5, "板の幅が 269.5 pt でない")
        drag(140, 0, "板の中央から左へ払う")
        drag(275, 20, "板の右端から左へ払う")
        drag(1, 400, "窓の左端から右へ払う")
        drag(320, 900, "detail の左端から右へ払う")
    }

    @MainActor
    func testCaptureIPadPlayer() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の撮影") }
        launchApp(capturePlayer: true)
        XCTAssertTrue(element(.button, "歌詞").waitForExistence(timeout: 15), "iPad full player が表示されなかった")
        settle()
        capture("playing")
    }

    /// iPad の sidebar 項目を直接 detail root に出し、深い遷移が残っていても次の選択で破棄する。
    @MainActor
    func capturePadSidebarChild(
        identifier: String, title: String, screen: String, then drillDown: (() -> Void)? = nil
    ) {
        let sidebar = padSidebarRow(identifier)
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

    /// iPad の参照で指定された実体を Search 結果から開き、Library の似た画面を代用しない。
    @MainActor
    func captureIPadSearchDetails() {
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
    func openSearchResult(
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
    func captureSearchPush() {
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
}
