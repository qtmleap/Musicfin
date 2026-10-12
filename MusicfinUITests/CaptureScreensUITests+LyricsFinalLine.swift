import Foundation
import XCTest

/// 最終行が他の行と同じ「上寄りの基準位置」まで送られるかを、参照の single の実歌詞で確かめる。
/// 歌詞の時刻は API から取り、合成はしない。最終行は下に続く本文が無いので、
/// 末尾の余白が足りないと基準位置まで上がらず、中ほどの行より下に残る。
extension CaptureScreensUITests {
    private struct FinalLineFixture {
        /// 時刻を持つ行の (index, 開始秒)。API の並びのまま。
        let timed: [(index: Int, start: TimeInterval)]
        let runtime: TimeInterval
        var lastIndex: Int {
            timed.max { $0.start == $1.start ? $0.index < $1.index : $0.start < $1.start }!.index
        }
        var lastStart: TimeInterval { timed.map(\.start).max()! }
        /// 前後 2 秒以上の間がある、全体の中ほどの行。シーク位置の誤差で隣の行にならないようにする。
        var middle: (index: Int, start: TimeInterval)? {
            let sorted = timed.sorted { $0.start < $1.start }
            let candidates = sorted.indices.dropFirst().dropLast().filter {
                sorted[$0].start - sorted[$0 - 1].start >= 2 && sorted[$0 + 1].start - sorted[$0].start >= 2
            }
            guard !candidates.isEmpty else { return nil }
            let target = (sorted.count - 1) / 2
            let best = candidates.min { abs($0 - target) < abs($1 - target) }!
            return (sorted[best].index, sorted[best].start)
        }
    }

    /// 操作帯が見えている状態（iPad 横長は右列が全高なので常にこちら）。
    @MainActor
    func testLyricsFinalLineReachesActiveAnchor() throws {
        continueAfterFailure = false
        let fixture = try finalLineFixture()
        try openFinalLinePlayer()
        let wide = app.windows.firstMatch.frame.width >= 900
        let seekBar = finalLineSeekBar()
        let middle = try XCTUnwrap(fixture.middle, "中ほどの基準行になる行が歌詞に無かった")

        XCTAssertTrue(seekBar.isHittable, "操作帯が見えている状態から始まらなかった")
        try seekToLine(middle.index, at: middle.start, fixture: fixture, seekBar: seekBar)
        let reference = finalLineAnchor(middle.index, wide: wide)
        capture("lyrics-final-line-middle-shown")

        try seekToLine(
            fixture.lastIndex, at: fixture.lastStart + 0.4, fixture: fixture, seekBar: seekBar)
        let last = finalLineAnchor(fixture.lastIndex, wide: wide)
        capture("lyrics-final-line-last-shown")
        XCTAssertEqual(last, reference, accuracy: 3, "操作帯が見えているとき、最終行が中ほどの行と同じ基準位置に届かなかった")
        assertFinalLineIsInUpperHalf(fixture.lastIndex)
        if !wide { XCTAssertTrue(seekBar.isHittable, "最終行へ送ったあと操作帯が消えた") }
    }

    /// iPhone で歌詞を読み進めて操作帯が隠れている状態。本文が延びても最終行は同じ基準位置へ届く。
    @MainActor
    func testLyricsFinalLineReachesActiveAnchorWithControlsHidden() throws {
        continueAfterFailure = false
        guard !isIPadCapture else { throw XCTSkip("操作帯が隠れるのは iPhone だけ") }
        let fixture = try finalLineFixture()
        try openFinalLinePlayer()
        let seekBar = finalLineSeekBar()
        let middle = try XCTUnwrap(fixture.middle, "中ほどの基準行になる行が歌詞に無かった")
        let window = app.windows.firstMatch

        // 位置を決めてから測れるよう、先に中ほどの行へ合わせてから上へ送って帯を隠す。
        try seekToLine(middle.index, at: middle.start, fixture: fixture, seekBar: seekBar)
        func drag(up: Bool) {
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.6 : 0.3))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.6))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
            settle()
        }
        var attempts = 0
        while seekBar.isHittable, attempts < 4 {
            drag(up: true)
            attempts += 1
        }
        XCTAssertFalse(seekBar.isHittable, "歌詞を上へ送っても操作帯が隠れなかった")

        // 隠れた状態で見えている行のうち、末尾から十分離れた行を基準にする。
        let probe = fixture.timed.map(\.index).first {
            let row = finalLineRow($0)
            return $0 != fixture.lastIndex && row.exists && row.isHittable
                && row.frame.minY > window.frame.height * 0.15
        }
        let referenceIndex = try XCTUnwrap(probe, "操作帯が隠れた状態で基準にできる行が見えなかった")
        finalLineRow(referenceIndex).tap()
        try waitSelected(referenceIndex)
        settle()
        let reference = finalLineAnchor(referenceIndex, wide: false)
        XCTAssertFalse(seekBar.isHittable, "基準行を合わせたあと操作帯が戻った")

        // 最終行は画面外なので、帯を出さない向きに送って行そのものをタップする。
        let last = finalLineRow(fixture.lastIndex)
        attempts = 0
        while !(last.exists && last.isHittable), attempts < 12 {
            drag(up: true)
            attempts += 1
        }
        guard last.exists, last.isHittable else {
            XCTFail("最終行 lyrics.line.\(fixture.lastIndex) まで \(attempts) 回送っても押せる位置に出なかった")
            return
        }
        last.tap()
        try waitSelected(fixture.lastIndex)
        settle()
        capture("lyrics-final-line-last-hidden")
        XCTAssertFalse(seekBar.isHittable, "最終行を選んだあと操作帯が戻った")
        XCTAssertEqual(
            finalLineAnchor(fixture.lastIndex, wide: false), reference, accuracy: 3,
            "操作帯が隠れているとき、最終行が他の行と同じ基準位置に届かなかった")
        assertFinalLineIsInUpperHalf(fixture.lastIndex)
    }

    // MARK: - 補助

    @MainActor
    private func finalLineRow(_ index: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "lyrics.line.\(index)").firstMatch
    }

    @MainActor
    private func finalLineSeekBar() -> XCUIElement {
        app.otherElements.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
        ).firstMatch
    }

    /// `scrollTo(anchor:)` は行の同じ割合の点を ScrollView の同じ割合の点へ合わせる。
    /// 行の高さが違っても比べられるよう、行の上端ではなく基準の点で測る。比率は LyricsView の 0.3455 / 0.15。
    @MainActor
    private func finalLineAnchor(_ index: Int, wide: Bool) -> CGFloat {
        let frame = finalLineRow(index).frame
        return frame.minY + (wide ? 0.3455 : 0.15) * frame.height
    }

    /// 基準位置が上寄りであることの絶対確認。比較だけだと両方が下に残る不具合を見逃す。
    @MainActor
    private func assertFinalLineIsInUpperHalf(_ index: Int) {
        let window = app.windows.firstMatch.frame
        let frame = finalLineRow(index).frame
        XCTAssertTrue(window.contains(frame), "最終行 \(frame) が画面 \(window) の外にある")
        XCTAssertLessThan(frame.midY, window.height * 0.6, "最終行が上寄りの基準位置ではなく下に残った: \(frame)")
    }

    @MainActor
    private func waitSelected(_ index: Int) throws {
        let row = finalLineRow(index)
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: row)
        guard XCTWaiter.wait(for: [selected], timeout: 10) == .completed else {
            throw FinalLineError.notSelected(index)
        }
    }

    /// シークバーの value（m:ss）を秒へ戻す。
    @MainActor
    private func finalLineSeconds(_ seekBar: XCUIElement) -> TimeInterval? {
        guard let value = seekBar.value as? String else { return nil }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    /// 現在位置からの距離で数回やり直し、行の開始時刻の直後へ着地させる。
    /// 行タップではなくシークバーを使うのは、画面外の行へ指を伸ばさず操作帯を出したまま測るため。
    @MainActor
    private func seekToLine(
        _ index: Int, at target: TimeInterval, fixture: FinalLineFixture, seekBar: XCUIElement
    ) throws {
        for _ in 0..<5 {
            let row = finalLineRow(index)
            if row.exists, row.isSelected { break }
            // バーの量子化で行の時刻より手前に止まったら、見えた実際の歌詞を押して正確に合わせる。
            if row.exists, row.isHittable {
                row.tap()
                break
            }
            let current = finalLineSeconds(seekBar) ?? 0
            func fraction(_ seconds: TimeInterval) -> CGFloat {
                CGFloat(min(max(seconds / fixture.runtime, 0.001), 0.999))
            }
            let start = seekBar.coordinate(withNormalizedOffset: CGVector(dx: fraction(current), dy: 0.5))
            let end = seekBar.coordinate(withNormalizedOffset: CGVector(dx: fraction(target), dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        print("LYRICS-FINAL target=\(index) seconds=\(target) seek=\(seekBar.value ?? "nil")")
        try waitSelected(index)
        // 追従のアニメーションと 450ms の猶予が終わるまで待ってから測る。
        settle()
    }

    private enum FinalLineError: Error, CustomStringConvertible {
        case notSelected(Int)
        case message(String)
        var description: String {
            switch self {
            case .notSelected(let index): "lyrics.line.\(index) が 10 秒以内に現在行にならなかった"
            case .message(let text): text
            }
        }
    }

    /// 参照の single を再生して一時停止し、歌詞表示にする。再生のまま測ると末尾で曲が終わる。
    @MainActor
    private func openFinalLinePlayer() throws {
        if isIPadCapture, ProcessInfo.processInfo.environment["MUSICFIN_CONFIGURE_FULL_SCREEN"] == "1" {
            try configureReleaseIPadFullScreen()
        }
        launchApp()
        if isIPadCapture, ProcessInfo.processInfo.environment["MUSICFIN_PLAYER_DRAG_ORIENTATION"] == "portrait" {
            XCUIDevice.shared.orientation = .portrait
            settle()
        }
        ensureSignedIn()
        selectTab("検索")
        XCTAssertTrue(
            openSearchResult(
                query: Self.lyricsReferenceTitle,
                identifier: "search.result.Audio.\(Self.lyricsReferenceItemID)"),
            "single の検索結果を ID で開けなかった")
        dismissKeyboard()
        let openPlayer = app.buttons.matching(
            NSPredicate(format: "label == %@", "\(Self.lyricsReferenceTitle), Open Player")
        ).firstMatch
        guard openPlayer.waitForExistence(timeout: 40) else {
            throw FinalLineError.message("参照の曲のミニプレイヤーが表示されなかった")
        }
        let mini = app.buttons["miniplayer.play-pause"]
        if ["Pause", "一時停止"].contains(mini.label) {
            mini.tap()
            settle()
        }
        openPlayer.tap()
        let title = app.staticTexts["nowplaying.title"]
        guard title.waitForExistence(timeout: 15) else { throw FinalLineError.message("フルプレイヤーが表示されなかった") }
        XCTAssertEqual(title.value as? String, Self.lyricsReferenceItemID, "album 版など別の個体を再生している")
        let transport = app.buttons["nowplaying.play-pause"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if ["Pause", "一時停止"].contains(transport.label) {
            transport.tap()
            settle()
        }
        let lyricsMode = app.buttons["nowplaying.mode.lyrics"]
        XCTAssertTrue(lyricsMode.waitForExistence(timeout: 10))
        lyricsMode.tap()
        XCTAssertTrue(finalLineSeekBar().waitForExistence(timeout: 10), "再生位置の slider が見つからなかった")
        guard finalLineRow(0).waitForExistence(timeout: 20) else {
            throw FinalLineError.message("歌詞の先頭行が表示されなかった")
        }
    }

    /// 認証済みの demo サーバーから、参照の single の歌詞時刻と長さを取る。
    /// 前提: `serverURL` / `username` / `password` で認証でき、`dca48c12…` に時刻付き歌詞がある。
    @MainActor
    private func finalLineFixture() throws -> FinalLineFixture {
        let base = try XCTUnwrap(URL(string: serverURL), "serverURL が不正")
        let authorization =
            #"MediaBrowser Client="Musicfin", Device="iOS Simulator", DeviceId="\#(UUID().uuidString)", Version="0.1.0""#
        func send(_ request: URLRequest, _ what: String) throws -> Data {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var output: (Data, URLResponse)?
            URLSession.shared.dataTask(with: request) { data, response, _ in
                if let data, let response { output = (data, response) }
                semaphore.signal()
            }.resume()
            guard semaphore.wait(timeout: .now() + 20) == .success, let output else {
                throw FinalLineError.message("\(what) が 20 秒以内に応答しなかった")
            }
            let status = (output.1 as? HTTPURLResponse)?.statusCode
            guard status == 200 else { throw FinalLineError.message("\(what) が HTTP \(status ?? -1) を返した") }
            return output.0
        }
        var login = URLRequest(url: base.appending(path: "/Users/AuthenticateByName"))
        login.httpMethod = "POST"
        login.setValue(authorization, forHTTPHeaderField: "Authorization")
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let session = try JSONDecoder().decode(APIAuthentication.self, from: send(login, "認証"))
        let token = authorization + #", Token="\#(session.accessToken)""#
        func get(_ url: URL, _ what: String) throws -> Any {
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "Authorization")
            return try JSONSerialization.jsonObject(with: send(request, what))
        }

        let lyricsURL = base.appending(path: "/Audio/\(Self.lyricsReferenceItemID)/Lyrics")
        let lyrics = try XCTUnwrap(get(lyricsURL, "歌詞取得") as? [String: Any])
        let rows = try XCTUnwrap(lyrics["Lyrics"] as? [[String: Any]], "歌詞の Lyrics 配列が無い")
        let timed = rows.enumerated().compactMap { index, row in
            (row["Start"] as? NSNumber).map { (index: index, start: $0.doubleValue / 10_000_000) }
        }
        guard timed.count >= 5 else {
            throw FinalLineError.message("時刻付き歌詞が \(timed.count) 行しかなく、中ほどと最終行を比べられない")
        }

        let finalIndex = timed.max { $0.start == $1.start ? $0.index < $1.index : $0.start < $1.start }!.index
        guard let finalText = rows[finalIndex]["Text"] as? String,
            !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw FinalLineError.message("最終の時刻付き歌詞が空で、文字の基準位置を比較できない") }

        var components = URLComponents(url: base.appending(path: "/Items"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "userId", value: session.user.id),
            URLQueryItem(name: "ids", value: Self.lyricsReferenceItemID),
            URLQueryItem(name: "fields", value: "RunTimeTicks"),
        ]
        let items = try XCTUnwrap(get(try XCTUnwrap(components.url), "曲情報取得") as? [String: Any])
        let item = try XCTUnwrap((items["Items"] as? [[String: Any]])?.first, "参照の single が API に無い")
        let ticks = try XCTUnwrap((item["RunTimeTicks"] as? NSNumber)?.doubleValue, "RunTimeTicks が無い")
        let runtime = ticks / 10_000_000
        XCTAssertEqual(runtime, 153, accuracy: 2, "参照の single (153 秒) ではない")
        return FinalLineFixture(timed: timed, runtime: runtime)
    }
}
