import Foundation
import UIKit
import XCTest

// MARK: - 再生/一時停止中のアートワーク寸法

extension CaptureScreensUITests {
    /// iPad のフルプレイヤーで、再生・停止・再開の各状態と向きごとにアートワーク周りの寸法を採取する。
    /// 見た目だけを縮め、曲情報や操作の位置まで動かしてしまう退行を防ぐ。
    @MainActor
    func testPadArtworkPlaybackSizes() throws {
        guard isIPadCapture else { throw XCTSkip("iPad 専用の診断") }
        try verifyDetailArtworkPlayback()
    }

    @MainActor
    func testPhoneDetailArtworkRemainsFixed() throws {
        guard !isIPadCapture else { throw XCTSkip("iPhone 専用の確認") }
        try verifyDetailArtworkPlayback()
    }

    @MainActor
    private func verifyDetailArtworkPlayback() throws {
        launchApp()
        ensureSignedIn()

        let album = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier != %@", "home.top-pick.", "home.top-pick.favorites")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 30))
        album.tap()
        let albumPlay = app.buttons["album.play"].firstMatch
        XCTAssertTrue(albumPlay.waitForExistence(timeout: 30))
        albumPlay.tap()
        let open = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()
        let title = app.staticTexts["nowplaying.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        settle()

        // 背面のミニプレイヤーも同じラベルを持つため、隠れている操作を選ばない。
        let transport = app.buttons["nowplaying.play-pause"]
        let pausedLabels = ["Play", "再生"]
        let playingLabels = ["Pause", "一時停止"]

        func waitLabel(_ labels: [String], _ message: String) {
            let match = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label IN %@", labels), object: transport)
            XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 10), .completed, message)
        }

        /// 向きの反映は非同期なので、窓の縦横が目的の向きになるまで述語で待つ。
        func rotate(to orientation: UIDeviceOrientation) {
            XCUIDevice.shared.orientation = orientation
            let window = app.windows.firstMatch
            let landscape = orientation.isLandscape
            let fits = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        let frame = window.frame
                        return frame.width > 0 && (frame.width > frame.height) == landscape
                    }
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [fits], timeout: 15), .completed, "向きが \(orientation.rawValue) へ変わらなかった")
            settle()
        }

        /// 実画面の撮影を添付する。native bridge の固定寸法には依存しない。
        func attach(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        func report(_ tag: String) {
            // 通常表示のアートワークは accessibilityHidden なので、窓・題名・操作の枠から間接的に読む。
            let window = app.windows.firstMatch.frame
            print(
                "[ArtworkDiag] \(tag) window=\(window) title=\(title.frame) transport=\(transport.frame) "
                    + "transportLabel=\(transport.label) available=\(window.width)x\(window.height)")
        }

        func shoot(_ tag: String) {
            settle()
            report(tag)
            attach(tag)
        }

        func exerciseState(_ prefix: String) {
            waitLabel(playingLabels, "\(prefix): 一時停止前に再生中になっていない")
            shoot("\(prefix)-playing")
            let artwork = app.buttons.matching(
                NSPredicate(
                    format: "label IN %@ AND identifier != %@", ["Back to Artwork", "アートワークへ戻る"], "album.overlay.close")
            ).firstMatch
            XCTAssertTrue(artwork.waitForExistence(timeout: 10))
            let playingFrame = artwork.frame
            let titleFrame = title.frame
            let transportFrame = transport.frame
            print("[ArtworkFrame] \(prefix) playing=\(playingFrame)")
            transport.tap()
            waitLabel(pausedLabels, "\(prefix): 一時停止できていない")
            shoot("\(prefix)-paused")
            print("[ArtworkFrame] \(prefix) paused=\(artwork.frame)")
            XCTAssertEqual(artwork.frame.width / playingFrame.width, isIPadCapture ? 0.9 : 1, accuracy: 0.02)
            XCTAssertEqual(artwork.frame.midX, playingFrame.midX, accuracy: 1)
            XCTAssertEqual(artwork.frame.midY, playingFrame.midY, accuracy: 1)
            XCTAssertEqual(title.frame.midY, titleFrame.midY, accuracy: 1)
            XCTAssertEqual(transport.frame.midY, transportFrame.midY, accuracy: 1)
            transport.tap()
            waitLabel(playingLabels, "\(prefix): 再開できていない")
            shoot("\(prefix)-resumed")
            XCTAssertEqual(artwork.frame.width, playingFrame.width, accuracy: 1)
        }

        func backToArtwork() {
            let back = app.buttons.matching(
                NSPredicate(
                    format: "label IN %@ AND identifier != %@", ["Back to Artwork", "アートワークへ戻る"], "album.overlay.close")
            ).firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 10), "アートワーク表示へ戻る操作が無い")
            back.tap()
            settle()
        }

        let orientations: [(UIDeviceOrientation, String)] =
            isIPadCapture
            ? [(.landscapeLeft, "landscape"), (.portrait, "portrait")] : [(.portrait, "phone")]
        for (orientation, name) in orientations {
            rotate(to: orientation)
            XCTAssertTrue(title.waitForExistence(timeout: 10), "\(name): 回転後にプレイヤーが残らなかった")

            element(.button, "歌詞").tap()
            exerciseState("\(name)-lyrics")
            backToArtwork()

            element(.button, "次に再生").tap()
            exerciseState("\(name)-queue")
            backToArtwork()
        }
    }
}
