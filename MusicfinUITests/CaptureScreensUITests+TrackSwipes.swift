import Foundation
import UIKit
import Vision
import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testTrackSwipePlayNextUsesIconOnly() throws {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()
        if !isIPadCapture { selectTab("ライブラリ") }
        XCTAssertNotNil(openCosmicAlbum(), "既存の参照アルバムを開けなかった")
        let albumRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.track."))
        XCTAssertTrue(albumRows.firstMatch.waitForExistence(timeout: 30))
        try verifyTrackSwipe(in: albumRows, name: "album-track-swipe")

        // 詳細のスクロール位置を持ち込まず、全曲一覧の入口も実際の操作で確認する。
        launchApp()
        ensureSignedIn()
        if isIPadCapture {
            let songs = padSidebarRow("sidebar.songs")
            XCTAssertTrue(songs.waitForExistence(timeout: 10))
            songs.tap()
        } else {
            selectTab("ライブラリ")
            let songs = app.buttons["library.songs"]
            XCTAssertTrue(songs.waitForExistence(timeout: 10))
            songs.tap()
        }
        let songRows = app.buttons.matching(identifier: "song.row")
        XCTAssertTrue(songRows.firstMatch.waitForExistence(timeout: 30))
        try verifyTrackSwipe(in: songRows, name: "songs-track-swipe")
    }

    @MainActor
    private func verifyTrackSwipe(in rows: XCUIElementQuery, name: String) throws {
        // 曲一覧の識別子は「…」にも伝わるので、曲名を持つ幅のある再生ボタンだけを比較する。
        var visibleRows = rows.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width > 100 }
        for _ in 0..<3 where visibleRows.count < 2 {
            app.swipeUp(velocity: .slow)
            settle()
            visibleRows = rows.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width > 100 }
        }
        let row = try XCTUnwrap(visibleRows.first, "スワイプできる曲行が無かった")
        let neighbor = try XCTUnwrap(visibleRows.dropFirst().first, "隣の曲行と比較できなかった")
        let header = app.navigationBars.firstMatch
        XCTAssertTrue(header.exists)
        settle()
        let rowFrame = row.frame
        let neighborFrame = neighbor.frame
        let headerFrame = header.frame
        let rowLabel = row.label
        _ = try captureTrackSwipe("\(name)-closed")

        // 全スワイプは操作を即実行するため、行幅の一部だけを引いて展開状態を保持する。
        let distance = min(130, rowFrame.width * 0.35)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: rowFrame.minX + rowFrame.width * 0.1, dy: rowFrame.midY))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.2)
        let action = app.buttons.matching(
            NSPredicate(format: "label IN %@ AND identifier != %@", ["Play Next", "次に再生"], "miniplayer.queue")
        ).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5), "先頭側のスワイプで「次に再生」が現れなかった")
        XCTAssertTrue(action.isHittable, "「次に再生」を操作できなかった")
        settle()
        assertTrackSwipeFrame(neighbor.frame, equals: neighborFrame, name: "隣の曲行")
        assertTrackSwipeFrame(header.frame, equals: headerFrame, name: "ヘッダー")
        let revealed = try captureTrackSwipe("\(name)-revealed")
        // 読み上げ用ラベルは残るため、文字の非表示はアクセシビリティではなく描画された画像で確かめる。
        try assertTrackSwipeHasNoVisibleTitle(in: action.frame, screenshot: revealed)

        let cancel = origin.withOffset(CGVector(dx: rowFrame.midX + distance / 2, dy: rowFrame.midY))
        cancel.press(
            forDuration: 0.05, thenDragTo: cancel.withOffset(CGVector(dx: -distance, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.2)
        let closed = NSPredicate { _, _ in !action.exists || !action.isHittable }
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation(for: closed, evaluatedWith: nil)], timeout: 5), .completed,
            "逆方向へ戻してもスワイプ操作が閉じなかった")
        settle()
        XCTAssertEqual(row.label, rowLabel)
        assertTrackSwipeFrame(row.frame, equals: rowFrame, name: "取り消した曲行")
        assertTrackSwipeFrame(neighbor.frame, equals: neighborFrame, name: "隣の曲行")
        assertTrackSwipeFrame(header.frame, equals: headerFrame, name: "ヘッダー")
        _ = try captureTrackSwipe("\(name)-cancelled")
    }

    @MainActor
    private func assertTrackSwipeFrame(_ actual: CGRect, equals expected: CGRect, name: String) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, "\(name) の横位置が変わった")
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, "\(name) の縦位置が変わった")
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, "\(name) の幅が変わった")
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, "\(name) の高さが変わった")
    }

    @MainActor
    private func captureTrackSwipe(_ name: String) throws -> UIImage {
        let environment = ProcessInfo.processInfo.environment
        if let bridge = environment["MUSICFIN_CAPTURE_BRIDGE_DIR"], !bridge.isEmpty,
            let directory = environment["MUSICFIN_SHOT_DIR"], !directory.isEmpty
        {
            capture(name)
            return try XCTUnwrap(UIImage(contentsOfFile: "\(directory)/\(name).png"), "native PNG が保存されなかった")
        }
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = environment["MUSICFIN_SHOT_DIR"], !directory.isEmpty {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: output.appendingPathComponent("\(name).png"))
        }
        return screenshot.image
    }

    @MainActor
    private func assertTrackSwipeHasNoVisibleTitle(in frame: CGRect, screenshot: UIImage) throws {
        let raw = try XCTUnwrap(screenshot.cgImage)
        let format = UIGraphicsImageRendererFormat()
        format.scale = sqrt(CGFloat(raw.width * raw.height) / (app.frame.width * app.frame.height))
        let upright = UIGraphicsImageRenderer(size: app.frame.size, format: format).image { _ in
            screenshot.draw(in: CGRect(origin: .zero, size: app.frame.size))
        }
        let source = try XCTUnwrap(upright.cgImage)
        let scale = CGFloat(source.width) / app.frame.width
        let region = frame.intersection(app.frame)
        let crop = try XCTUnwrap(
            source.cropping(
                to: CGRect(
                    x: region.minX * scale, y: region.minY * scale,
                    width: region.width * scale, height: region.height * scale
                ).integral))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "ja-JP"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: crop).perform([request])
        let recognized =
            request.results?.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").lowercased() ?? ""
        XCTAssertFalse(
            ["play", "next", "次に", "再生"].contains { recognized.contains($0) },
            "アイコンだけのスワイプ操作に題名が描かれていた: \(recognized)")
    }
}
