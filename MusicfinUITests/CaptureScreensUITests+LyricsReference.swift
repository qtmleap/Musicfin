import Foundation
import XCTest

extension CaptureScreensUITests {
    static let lyricsReferenceItemID = "dca48c1253e72a5da8776738f3770777"
    static let lyricsReferenceTitle = "極私的極彩色アンサー"

    /// 参照と同じ単曲（album 版ではなく 153 秒の single）の歌詞レイアウトを 0:00 で測り、
    /// 現在行の y と行ピッチを物理参照の実測値に対して検証し、同じ状態を撮影する。
    @MainActor
    func testLyricsReferenceBaselineLayout() throws {
        guard isIPadCapture else { throw XCTSkip("iPad の参照比較") }
        launchApp()
        ensureSignedIn()

        // 同名の album 版が別 ID で存在するため、再生前に API で single の ID と長さを固定する。
        let item = try XCTUnwrap(apiItem(id: Self.lyricsReferenceItemID), "参照の single を API で取得できなかった")
        XCTAssertEqual(item.id, Self.lyricsReferenceItemID)
        XCTAssertEqual(item.name, Self.lyricsReferenceTitle)

        selectTab("検索")
        XCTAssertTrue(
            openSearchResult(
                query: Self.lyricsReferenceTitle,
                identifier: "search.result.Audio.\(Self.lyricsReferenceItemID)"),
            "single の検索結果を ID で開けなかった")
        dismissKeyboard()

        // 検索結果の曲行は直接再生する。
        let openPlayer = app.buttons.matching(
            NSPredicate(format: "label == %@", "\(Self.lyricsReferenceTitle), Open Player")
        ).firstMatch
        guard openPlayer.waitForExistence(timeout: 40) else {
            XCTFail("参照の曲のミニプレイヤーが表示されなかった")
            return
        }
        // 再生中の時間表示を待ち続けないよう、開く前にミニプレイヤーで停止する。
        pauseIfPlaying(app.buttons["miniplayer.play-pause"])
        openPlayer.tap()

        let title = app.staticTexts["nowplaying.title"]
        guard title.waitForExistence(timeout: 15) else {
            XCTFail("フルプレイヤーが表示されなかった")
            return
        }
        XCTAssertEqual(title.label, Self.lyricsReferenceTitle)
        XCTAssertEqual(title.value as? String, Self.lyricsReferenceItemID, "album 版など別の個体を再生している")

        // 位置を決めてから測るため、先に一時停止する。
        let transport = app.buttons["nowplaying.play-pause"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        pauseIfPlaying(transport)

        let lyricsMode = app.buttons["nowplaying.mode.lyrics"]
        XCTAssertTrue(lyricsMode.waitForExistence(timeout: 10))
        lyricsMode.tap()

        // 既存の seek 手順と同じく、シークバー先頭への短いドラッグで 0:00 に戻す。
        let seekBar = app.otherElements.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
        ).firstMatch
        guard seekBar.waitForExistence(timeout: 10) else {
            XCTFail("再生位置の slider が見つからなかった")
            return
        }
        seekToStart(seekBar)

        let firstRow = lyricLineElement(0)
        guard firstRow.waitForExistence(timeout: 20) else {
            XCTFail("歌詞の先頭行が表示されなかった")
            return
        }
        XCTAssertFalse(firstRow.label.isEmpty, "先頭行の歌詞が空だった")
        XCTAssertEqual(title.value as? String, Self.lyricsReferenceItemID, "歌詞表示中に曲が切り替わった")
        // 先頭行の本文は物理参照の 1 行目との一致を必須にする。比較元が無いまま通すと別の歌詞でも通ってしまう。
        XCTAssertEqual(firstRow.label, "藍色に溶く 鈍色の最適解", "先頭行が物理参照と一致しなかった")
        settle()
        reportLyricRows(state: "baseline-0")
        capture("lyrics-reference-baseline-0")

        // 表示の 0:00 は小数を含むので、参照の現在行へ実際の歌詞時刻で合わせる。
        firstRow.tap()
        let firstSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == true"), object: firstRow)
        XCTAssertEqual(XCTWaiter.wait(for: [firstSelected], timeout: 10), .completed)
        settle()
        reportLyricRows(state: "active-0")
        assertActiveRowLayout(0)
        capture("lyrics-reference-active-0")

        // 行タップは seek になるが、曲の時刻データや再生内容は変えない。
        for index in [1, 2] {
            let line = lyricLineElement(index)
            guard line.waitForExistence(timeout: 10) else {
                XCTFail("歌詞の \(index) 行目が表示されなかった")
                continue
            }
            line.tap()
            let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: line)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed, "\(index) 行目が現在行にならなかった")
            pauseIfPlaying(transport)
            settle()
            reportLyricRows(state: "active-\(index)")
            assertActiveRowLayout(index)
            capture("lyrics-reference-active-\(index)")
        }
        XCTAssertEqual(title.value as? String, Self.lyricsReferenceItemID)
    }

    /// 参照の AX 実測：現在行の minY は 348 pt、行ピッチは 97.5 pt（行 57.5 pt ＋ 間隔 40 pt）。
    /// 狭い表示とは値が違うので、横長になる 1366x1024 でだけ検証する。
    @MainActor
    private func assertActiveRowLayout(_ index: Int) {
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(window.width, 1366, accuracy: 1, "1366x1024 の iPad で実行する必要がある")
        XCTAssertEqual(window.height, 1024, accuracy: 1, "1366x1024 の iPad で実行する必要がある")
        let current = lyricLineElement(index)
        let next = lyricLineElement(index + 1)
        XCTAssertTrue(current.exists && next.exists, "\(index) 行目と次の行が見つからなかった")
        XCTAssertEqual(current.frame.minY, 348, accuracy: 1, "\(index) 行目の現在行の y が参照とずれた")
        XCTAssertEqual(next.frame.minY - current.frame.minY, 97.5, accuracy: 1, "行ピッチが参照とずれた")
    }

    @MainActor
    private func lyricLineElement(_ index: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "lyrics.line.\(index)").firstMatch
    }

    @MainActor
    private func pauseIfPlaying(_ transport: XCUIElement) {
        if ["Pause", "一時停止"].contains(transport.label) {
            transport.tap()
            settle()
        }
    }

    @MainActor
    private func seekToStart(_ seekBar: XCUIElement) {
        var attempts = 0
        while seekBar.value as? String != "0:00", attempts < 3 {
            let start = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let beginning = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: beginning)
            attempts += 1
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        XCTAssertEqual(seekBar.value as? String, "0:00", "再生位置を 0:00 に戻せなかった")
    }

    /// 先頭 4 行の frame を出力して添付する。差分は後続の assertion を決める根拠にする。
    @MainActor
    private func reportLyricRows(state: String) {
        var lines = ["LYRICS_REFERENCE \(state) window=\(app.windows.firstMatch.frame)"]
        var previousY: CGFloat?
        for index in 0..<4 {
            let row = lyricLineElement(index)
            guard row.exists else {
                lines.append("LYRICS_REFERENCE \(state) lyrics.line.\(index) missing")
                continue
            }
            let frame = row.frame
            let pitch = previousY.map { String(format: "%.1f", frame.minY - $0) } ?? "-"
            previousY = frame.minY
            lines.append(
                "LYRICS_REFERENCE \(state) lyrics.line.\(index) isSelected=\(row.isSelected) "
                    + String(
                        format: "x=%.1f y=%.1f w=%.1f h=%.1f pitch=%@", frame.minX, frame.minY, frame.width,
                        frame.height, pitch)
                    + " label=\(row.label)")
        }
        let report = lines.joined(separator: "\n")
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "lyrics-reference-\(state)-frames"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
