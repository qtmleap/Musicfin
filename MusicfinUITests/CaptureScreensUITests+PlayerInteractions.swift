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
        element(.button, "歌詞").tap()
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
        element(.button, "次に再生").tap()
        settle()
        drag(0.75, 0.3, 0.75, 0.7)
        XCTAssertTrue(title.exists, "右のキュー操作で閉じた")
        capture("player-queue-dismiss-region")
        drag(0.2, 0.3, 0.2, 0.7)
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "キュー表示を左側から閉じられなかった")
        XCTAssertTrue(app.buttons["miniplayer.play-pause"].isHittable)
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
