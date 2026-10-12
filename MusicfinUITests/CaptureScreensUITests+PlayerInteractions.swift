import Foundation
import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testPadSidebarSingleTapTargets() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp()
        ensureSignedIn()
        for (destination, x) in [("albums", 245.0), ("artists", 40.0), ("songs", 245.0), ("home", 40.0)] {
            let row = padSidebarRow("sidebar.\(destination)")
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            // 文字の中心だけでは、行の空白やアイコンにある認識競合を見逃す。
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: row.frame.midY)).tap()
            settle()
            XCTAssertTrue(row.isSelected, "通常の単押しで \(destination) に切り替わらなかった")
        }
        let album = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@", "home.top-pick.", "home.top-pick.favorites")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
        let close = app.buttons["album.overlay.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        let home = padSidebarRow("sidebar.home")
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 245, dy: home.frame.midY)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), "同じ Home の再選択で詳細が閉じなかった")
        album.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        let artists = padSidebarRow("sidebar.artists")
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 40, dy: artists.frame.midY)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        XCTAssertTrue(artists.isSelected)
        capture("sidebar-single-tap")
    }

    @MainActor
    func testPadPlaylistSwitchReloadsShuffleSource() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp()
        ensureSignedIn()
        let fixtures = try playlistInteractionFixtures()
        XCTAssertGreaterThanOrEqual(fixtures.count, 2, "異なる曲を持つプレイリストが 2 つ必要")
        guard fixtures.count >= 2 else { return }
        let first = fixtures[0]
        let second = fixtures[1]
        selectInteractionPlaylist(first.item)
        let firstTrack = app.buttons["playlist.track.\(first.tracks[0].id)"]
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 20))
        selectInteractionPlaylist(second.item)
        XCTAssertEqual(app.staticTexts["playlist.detail"].label, second.item.name)
        XCTAssertTrue(
            app.buttons["playlist.track.\(second.tracks[0].id)"].waitForExistence(timeout: 20), "前の作品の曲一覧が残った")
        XCTAssertFalse(firstTrack.exists, "切り替え後にも前のプレイリストの曲が残った")
        app.buttons["album.shuffle"].tap()
        let openPlayer = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 20))
        openPlayer.tap()
        let title = app.staticTexts["nowplaying.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(Set(second.tracks.map(\.name)).contains(title.label), "別のプレイリストをシャッフル再生した")
        element(.button, "次に再生").tap()
        settle()
        let queued = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue.upcoming."))
        let expected = Set(second.tracks.map { "queue.upcoming.\($0.id)" })
        for row in queued.allElementsBoundByIndex {
            XCTAssertTrue(expected.contains(row.identifier), "前の作品の曲が再生キューへ混入した")
        }
        capture("playlist-switch-shuffle")
    }

    @MainActor
    func testPadFullPlayerDismissRegions() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        launchApp()
        ensureSignedIn()
        let album = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@", "home.top-pick.", "home.top-pick.favorites")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
        let play = app.buttons["album.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let title = app.staticTexts["nowplaying.title"]
        let window = app.windows.firstMatch
        func openPlayer() {
            let open = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 20))
            open.tap()
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            settle()
        }
        func drag(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x1, dy: y1))
                .press(
                    forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: x2, dy: y2)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
            settle()
        }
        openPlayer()
        drag(0.85, 0.3, 0.85, 0.34)
        XCTAssertTrue(title.exists, "短い動きで閉じた")
        drag(0.85, 0.25, 0.85, 0.65)
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "通常表示を右側から閉じられなかった")
        openPlayer()
        app.buttons["nowplaying.mode.lyrics"].tap()
        settle()
        drag(0.75, 0.3, 0.75, 0.7)
        XCTAssertTrue(title.exists, "右の歌詞操作で閉じた")
        drag(0.55, 0.3, 0.4, 0.7)
        XCTAssertTrue(title.exists, "右側で始めた操作が途中で終了操作へ変わった")
        let seek = app.otherElements.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
        ).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10))
        let origin = window.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: seek.frame.midX, dy: seek.frame.midY))
            .press(
                forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: seek.frame.midX + 90, dy: seek.frame.midY + 150)))
        settle()
        XCTAssertTrue(title.exists, "シークバーから始めた操作で閉じた")
        capture("player-lyrics-dismiss-region")
        drag(0.4, 0.3, 0.5, 0.7)
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "左側で始めた操作を右側で離しても閉じなかった")
        openPlayer()
        app.buttons["nowplaying.mode.queue"].tap()
        settle()
        drag(0.75, 0.3, 0.75, 0.7)
        XCTAssertTrue(title.exists, "右のキュー操作で閉じた")
        capture("player-queue-dismiss-region")
        drag(0.2, 0.3, 0.2, 0.7)
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "キュー表示を左側から閉じられなかった")
        XCTAssertTrue(app.buttons["miniplayer.play-pause"].isHittable)
    }

    /// 指を止めたまま保持する本物の操作で、全画面プレイヤーの追従・復帰・終了を確かめる。
    /// 保持中の動きは root 側の画面録画で見るため、ここでは各操作の前後に時刻と frame を出す。
    /// 縦画面の確認は `MUSICFIN_PLAYER_DRAG_ORIENTATION=portrait` で切り替える。
    @MainActor
    func testPadFullPlayerInteractiveDrag() throws {
        continueAfterFailure = false
        guard isIPadCapture else { throw XCTSkip("iPad 専用の確認") }
        if ProcessInfo.processInfo.environment["MUSICFIN_CONFIGURE_FULL_SCREEN"] == "1" {
            try configureReleaseIPadFullScreen()
        }
        launchApp(checksReferenceSize: false)
        if ProcessInfo.processInfo.environment["MUSICFIN_PLAYER_DRAG_ORIENTATION"] == "portrait" {
            XCUIDevice.shared.orientation = .portrait
            settle()
        }
        ensureSignedIn()
        let album = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@", "home.top-pick.", "home.top-pick.favorites")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        album.tap()
        let play = app.buttons["album.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        let title = app.staticTexts["nowplaying.title"]
        let artwork = app.buttons.matching(
            NSPredicate(
                format: "label IN %@ AND identifier != %@", ["Back to Artwork", "アートワークへ戻る"], "album.overlay.close")
        ).firstMatch
        let window = app.windows.firstMatch
        let origin = window.coordinate(withNormalizedOffset: .zero)

        func openPlayer() {
            let open = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 20))
            open.tap()
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            settle()
        }
        func log(_ event: String) {
            let titleFrame = title.exists ? "\(title.frame)" : "gone"
            let artworkFrame = artwork.exists ? "\(artwork.frame)" : "n/a"
            print(
                "PLAYER-DRAG epoch=\(Date().timeIntervalSince1970) \(event) title=\(titleFrame) artwork=\(artworkFrame)"
            )
        }
        // 指を離さず 2 秒保持してから離す。速度は slow 固定で、追従を録画から読めるようにする。
        func pull(_ name: String, from start: CGPoint, dy: CGFloat) {
            log("\(name) before")
            origin.withOffset(CGVector(dx: start.x, dy: start.y))
                .press(
                    forDuration: 0.1,
                    thenDragTo: origin.withOffset(CGVector(dx: start.x, dy: start.y + dy)),
                    withVelocity: .slow, thenHoldForDuration: 2)
            // 終了アニメーション中の要素は exists と frame の間に消えるため、ここでは時刻だけ残す。
            print("PLAYER-DRAG epoch=\(Date().timeIntervalSince1970) \(name) released")
        }
        func attach(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func center(_ element: XCUIElement) -> CGPoint { CGPoint(x: element.frame.midX, y: element.frame.midY) }
        func openMode(_ mode: String) {
            openPlayer()
            let button = app.buttons["nowplaying.mode.\(mode)"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            settle()
        }

        openPlayer()
        let size = window.frame
        let bodyLeft = CGPoint(x: size.width * 0.2, y: size.height * 0.3)
        let bodyRight = CGPoint(x: size.width * 0.85, y: size.height * 0.3)
        let header = CGPoint(x: size.width * (size.width >= 900 ? 0.2 : 0.5), y: 40)

        // 部分的な引き（40 pt・150 pt・画面高の約 20% の保持）は離すと元の位置へ戻り、閉じない。
        let baseline = center(title)
        let baselineArtwork = artwork.exists ? center(artwork) : nil
        func assertReturnedToBaseline(_ name: String) {
            settle()
            XCTAssertTrue(title.exists, "\(name): 引いて離したのに閉じた")
            XCTAssertEqual(center(title).x, baseline.x, accuracy: 2, "\(name): 離したあと title の x が元に戻らなかった")
            XCTAssertEqual(center(title).y, baseline.y, accuracy: 2, "\(name): 離したあと title の y が元に戻らなかった")
            if let baselineArtwork, artwork.exists {
                XCTAssertEqual(center(artwork).x, baselineArtwork.x, accuracy: 2, "\(name): artwork の x が戻らなかった")
                XCTAssertEqual(center(artwork).y, baselineArtwork.y, accuracy: 2, "\(name): artwork の y が戻らなかった")
            }
        }
        // 閉じる側は画面高の 40%。縦横どちらの向きでも同じ割合で確定させる。
        let closeDistance = size.height * 0.4
        pull("short-cancel", from: bodyLeft, dy: 40)
        assertReturnedToBaseline("short-cancel-40")
        pull("partial-return-150", from: bodyLeft, dy: 150)
        assertReturnedToBaseline("partial-return-150")
        pull("partial-return-20pct", from: bodyLeft, dy: size.height * 0.2)
        assertReturnedToBaseline("partial-return-20pct")
        log("partial returns settled")
        attach("player-drag-cancel-baseline")

        // スライダー内から始まった縦の指移動も、プレイヤーを動かす操作にはしない。
        let seek = app.otherElements.matching(
            NSPredicate(format: "label IN %@", ["Playback Position", "再生位置"])
        ).firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 10))
        pull("seek-excluded", from: center(seek), dy: 150)
        settle()
        XCTAssertTrue(title.exists)
        XCTAssertEqual(center(title).y, baseline.y, accuracy: 2)

        // 長く引いて離すと閉じる。
        pull("long-close", from: bodyLeft, dy: closeDistance)
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "画面高の 40% (\(Int(closeDistance))pt) 引いて離しても閉じなかった")

        // 歌詞とキューは同じ規則: 右の本文は固定のまま、左の本文と header は閉じる。
        for mode in ["lyrics", "queue"] {
            openMode(mode)
            attach("player-drag-\(mode)")
            let base = center(title)
            pull("\(mode)-right", from: bodyRight, dy: closeDistance)
            settle()
            XCTAssertTrue(title.exists, "\(mode) の右本文を引いて閉じた")
            XCTAssertEqual(center(title).y, base.y, accuracy: 2, "\(mode) の右本文を引いたあと title が動いたままになった")
            if size.width >= 900 {
                pull("\(mode)-left", from: bodyLeft, dy: closeDistance)
                XCTAssertTrue(title.waitForNonExistence(timeout: 10), "\(mode) の左本文を画面高の 40% 引いても閉じなかった")
                openMode(mode)
            }
            pull("\(mode)-header", from: header, dy: closeDistance)
            XCTAssertTrue(title.waitForNonExistence(timeout: 10), "\(mode) の header から画面高の 40% 引いても閉じなかった")
        }
    }

    @MainActor
    func testPhonePlayerDismissRemainsAvailable() throws {
        guard !isIPadCapture else { throw XCTSkip("iPhone 専用の確認") }
        launchApp()
        ensureSignedIn()
        app.terminate()
        launchApp(capturePlayer: true)
        let title = app.staticTexts["nowplaying.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "iPhone の標準終了が妨げられた")
    }

    @MainActor
    private func selectInteractionPlaylist(_ playlist: APISearchResult.Item) {
        let row = padSidebarRow("sidebar.playlist.\(playlist.id)")
        for _ in 0..<6 {
            if row.exists && row.isHittable { break }
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8))
                .press(
                    forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)))
            settle()
        }
        XCTAssertTrue(row.isHittable)
        row.tap()
        settle()
        XCTAssertTrue(row.isSelected, "プレイリストが単押しで選択されなかった")
        XCTAssertTrue(app.staticTexts["playlist.detail"].waitForExistence(timeout: 20))
    }

    private struct InteractionPlaylist {
        let item: APISearchResult.Item
        let tracks: [APISearchResult.Item]
    }

    private func playlistInteractionFixtures() throws -> [InteractionPlaylist] {
        let base = try XCTUnwrap(URL(string: serverURL))
        let authorization =
            #"MediaBrowser Client="Musicfin", Device="iOS Simulator", DeviceId="\#(UUID().uuidString)", Version="0.1.0""#
        var request = URLRequest(url: base.appending(path: "/Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let authenticationData = try interactionAPIData(request)
        let session = try JSONDecoder().decode(APIAuthentication.self, from: authenticationData)
        func items(path: String, query: [URLQueryItem]) throws -> [APISearchResult.Item] {
            var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
            components.queryItems = query + [URLQueryItem(name: "userId", value: session.user.id)]
            var request = URLRequest(url: try XCTUnwrap(components.url))
            request.setValue(authorization + #", Token="\#(session.accessToken)""#, forHTTPHeaderField: "Authorization")
            return try JSONDecoder().decode(APISearchResult.self, from: interactionAPIData(request)).items
        }
        let playlists = try items(
            path: "/Items",
            query: [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
                URLQueryItem(name: "SortBy", value: "SortName"), URLQueryItem(name: "Limit", value: "100"),
            ])
        var result: [InteractionPlaylist] = []
        for playlist in playlists {
            let tracks = try items(path: "/Playlists/\(playlist.id)/Items", query: [])
            guard !tracks.isEmpty else { continue }
            if let first = result.first, !Set(first.tracks.map(\.id)).isDisjoint(with: tracks.map(\.id)) { continue }
            result.append(InteractionPlaylist(item: playlist, tracks: tracks))
            if result.count == 2 { break }
        }
        return result
    }

    private func interactionAPIData(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output: (Data, URLResponse)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response { output = (data, response) }
            semaphore.signal()
        }.resume()
        XCTAssertEqual(semaphore.wait(timeout: .now() + 20), .success)
        let response = try XCTUnwrap(output)
        XCTAssertEqual((response.1 as? HTTPURLResponse)?.statusCode, 200)
        return response.0
    }
}
