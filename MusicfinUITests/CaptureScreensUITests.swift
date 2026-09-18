import Foundation
import XCTest

/// 主要画面を同じ手順で撮影し、`docs/screenshots/manifest.json`（スクリプトが生成）経由で比較できるようにする。
/// 保存先は `MUSICFIN_SHOT_DIR` で受け取る。
/// 文字サイズは `MUSICFIN_CONTENT_SIZE` で受け取る（例 `UICTContentSizeCategoryAccessibilityXXXL`）。
/// 未指定なら Simulator の既定サイズのままにする。
/// 表示ラベルを基本とし、同名操作を区別できない箇所だけ安定した識別子を使う。
final class CaptureScreensUITests: XCTestCase {
    private static let defaultServerURL = "https://jellyfin.tkgstrator.work"
    private static let defaultUsername = "demo"
    static let replyItemID = "edbbb8025d78bddebb6360962b27df89"
    static let rayItemID = "43612d6d33406faf4cbaba89f5bd427b"
    static let meltItemID = "92bdf95b3902c28a2bc147d651a9f63f"
    static let togenashiTogeariArtistID = "f739583459f481ecc459cee23e70fc3d"
    static let heartOnMySleeveAlbumID = "67c8bdd170cbb7e32ef9b0dd6b8f7b69"
    static let cosmicAlbumID = "982d12de5338d828ea535c7aa65e0e05"
    static let cosmicReferenceTitle = "Cosmic Princess Kaguya!"

    struct APIAuthentication: Decodable {
        struct User: Decodable {
            let id: String
            private enum CodingKeys: String, CodingKey { case id = "Id" }
        }
        let user: User
        let accessToken: String

        private enum CodingKeys: String, CodingKey {
            case user = "User"
            case accessToken = "AccessToken"
        }
    }

    struct APISearchResult: Decodable {
        struct Item: Decodable {
            let id: String
            let name: String
            let type: String
            let parentID: String?

            private enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
                case type = "Type"
                case parentID = "ParentId"
            }
        }
        let items: [Item]

        private enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    var serverURL: String {
        ProcessInfo.processInfo.environment["MUSICFIN_SERVER_URL"] ?? Self.defaultServerURL
    }

    var username: String {
        ProcessInfo.processInfo.environment["MUSICFIN_USERNAME"] ?? Self.defaultUsername
    }

    var password: String {
        ProcessInfo.processInfo.environment["MUSICFIN_PASSWORD"] ?? ""
    }

    private var captureBridgeDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["MUSICFIN_CAPTURE_BRIDGE_DIR"],
            !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // XCUIApplication は MainActor 隔離なので、テスト本体と補助メソッドを MainActor に置く。
    // クラス自体を MainActor にすると XCTestCase の nonisolated な override と衝突する。
    var app: XCUIApplication!
    private var shotDirectory: URL?
    /// `UICTContentSizeCategory…` の名前をそのまま持つ。未指定なら nil。
    private var contentSizeCategory: String?
    var capturedNames: Set<String> = []
    var skippedScreens: [String] = []

    var isIPadCapture: Bool {
        ProcessInfo.processInfo.environment["MUSICFIN_IPAD_CAPTURE"] == "1"
    }

    /// 英語固定の撮影でも同じ操作手順を使えるよう、既存の日本語ラベルを英訳して検索する。
    @MainActor
    func element(_ type: XCUIElement.ElementType, _ japanese: String) -> XCUIElement {
        let english: [String: String] = [
            "アカウント": "Account", "接続": "Connect", "サーバーを変更": "Change Server",
            "閉じる": "Close", "ログアウト": "Sign Out", "キャンセル": "Cancel",
            "ユーザー名": "Username", "ログイン": "Sign In", "最近追加したアルバム": "Recently Added Albums",
            "ライブラリ": "Library", "アルバム": "Albums", "アーティスト": "Artists", "プレイリスト": "Playlists",
            "ジャンル": "Genres", "曲": "Songs", "お気に入りの曲": "Favorite Songs", "再生": "Play", "歌詞": "Lyrics",
            "すべてのアルバムを確認中…": "Loading all albums…", "一時停止": "Pause", "次に再生": "Play Next",
            "アルバムがありません": "No Albums", "アートワークへ戻る": "Back to Artwork",
            "アーティストがありません": "No Artists", "曲がありません": "No Songs",
        ]
        return app.descendants(matching: type)[english[japanese] ?? japanese]
    }

    /// 板の行は `List(selection:)` の選択肢なので button ではなく、選択状態を持つ静的テキストとして出る。
    /// 行に付けた識別子は記号側にも伝わるため、行の幅を持つ静的テキストだけを引く。
    @MainActor
    func padSidebarRow(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .staticText).matching(identifier: identifier).firstMatch
    }

    override func setUpWithError() throws {
        // 1 つの画面が撮れなくても残りは撮り切りたい。
        continueAfterFailure = true
        // 画面遷移と実 API 待機を 1 method で行うため、Xcode の 1 分既定値では完走できない。
        executionTimeAllowance = 1_800

        let environment = ProcessInfo.processInfo.environment
        if let directory = environment["MUSICFIN_SHOT_DIR"], !directory.isEmpty {
            shotDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        }
        if let category = environment["MUSICFIN_CONTENT_SIZE"], !category.isEmpty {
            contentSizeCategory = category
        }
    }

    @MainActor
    func launchApp(capturePlayer: Bool = false) {
        // 前の method の Simulator 状態に依存せず、毎回 portrait から実際の横向き遷移を起こす。
        if isIPadCapture {
            XCUIDevice.shared.orientation = .portrait
        }
        app = XCUIApplication()
        app.launchEnvironment["MUSICFIN_SHOT_DIR"] = shotDirectory?.path ?? ""
        if capturePlayer { app.launchEnvironment["MUSICFIN_CAPTURE_PLAYER"] = "1" }
        // test runner のロケールは app 子プロセスへ継承されないため、比較条件を起動引数と環境の両方で固定する。
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["AppleLanguages"] = "(en)"
        app.launchEnvironment["AppleLocale"] = "en_US"
        // 文字サイズは起動引数でしか差し替えられない（Simulator 全体の設定を触らずに済む）。
        // 未指定のときは引数ごと足さないので、既定の撮影は今までと同じ経路を通る。
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        if isIPadCapture {
            ensureIPadLandscape()
        }
    }

    /// orientation の設定値ではなく app window の実寸を待ち、Air 系で遷移が遅れても縦画面を撮らない。
    @MainActor
    private func ensureIPadLandscape() {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 10) else {
            XCTFail("iPad の app window が表示されなかった（orientation: \(XCUIDevice.shared.orientation.rawValue)）")
            return
        }

        for _ in 0..<3 {
            XCUIDevice.shared.orientation = .portrait
            app.activate()
            _ = waitForWindow(window, landscape: false, timeout: 5)

            XCUIDevice.shared.orientation = .landscapeLeft
            // 回転イベントは app が前面のまま発火させる。設定直後の activate は scene を
            // portrait geometry で再アクティブ化し、Air 系では要求を打ち消してしまう。
            if waitForWindow(window, landscape: true, timeout: 10) {
                let image = XCUIScreen.main.screenshot().image
                XCTAssertEqual(image.size.width * image.scale, 2732, "iPad 撮影開始前の幅が参照と異なる")
                XCTAssertEqual(image.size.height * image.scale, 2048, "iPad 撮影開始前の高さが参照と異なる")
                return
            }
        }

        let frame = window.frame
        XCTFail(
            "iPad が横向きにならなかった（frame: \(frame.width)×\(frame.height), orientation: \(XCUIDevice.shared.orientation.rawValue)）"
        )
    }

    /// CoreSimulator の回転完了は非同期なので、window の縦横が目的どおりになるまでだけ bounded wait する。
    @MainActor
    private func waitForWindow(_ window: XCUIElement, landscape: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let frame = window.frame
            if landscape ? frame.width > frame.height : frame.height > frame.width { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        let frame = window.frame
        return landscape ? frame.width > frame.height : frame.height > frame.width
    }

    @MainActor
    var isRunning: Bool { app.state == .runningForeground }

    /// 再生中にアプリが落ちた場合でも残りの画面を撮れるよう、立ち上げ直してホームまで戻す。
    @MainActor
    func recoverIfTerminated() {
        guard !isRunning else { return }
        XCTFail("再生中にアプリが終了した（クラッシュログを確認すること）")
        launchApp()
        ensureSignedIn()
    }

    /// 遷移アニメーションが終わるのを待ってから撮る。
    @MainActor
    func settle() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
    }

    /// 結果バンドルへの添付と、比較しやすいようファイルへの書き出しを両方行う。ファイル名は `<画面>.png`。
    @MainActor
    func capture(_ screen: String) {
        let fileName = "\(screen).png"
        guard let shotDirectory, let bridge = captureBridgeDirectory else {
            XCTFail("screenshot または capture bridge の保存先が設定されていない")
            return
        }
        do {
            try FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
            let request = bridge.appendingPathComponent("\(screen).request")
            let pending = bridge.appendingPathComponent(".\(screen).request.tmp")
            let ack = bridge.appendingPathComponent("\(screen).ack")
            let failure = bridge.appendingPathComponent("\(screen).error")
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: ack)
            try? FileManager.default.removeItem(at: failure)
            try screen.data(using: .utf8)?.write(to: pending)
            try FileManager.default.moveItem(at: pending, to: request)

            // native framebuffer が保存されるまで現在の semantic 状態を保持する。
            let deadline = Date(timeIntervalSinceNow: 20)
            while !FileManager.default.fileExists(atPath: ack.path),
                !FileManager.default.fileExists(atPath: failure.path), Date() < deadline
            {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            if FileManager.default.fileExists(atPath: failure.path) {
                let detail = try String(contentsOf: failure, encoding: .utf8)
                XCTFail("native screenshot worker が失敗した: \(fileName) — \(detail)")
                return
            }
            guard FileManager.default.fileExists(atPath: ack.path) else {
                XCTFail("native screenshot worker が timeout した: \(fileName)")
                return
            }
            let output = shotDirectory.appendingPathComponent(fileName)
            let png = try Data(contentsOf: output)
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = fileName
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("native screenshot を受け取れなかった: \(fileName) — \(error)")
            return
        }
        capturedNames.insert(screen)
    }
}
