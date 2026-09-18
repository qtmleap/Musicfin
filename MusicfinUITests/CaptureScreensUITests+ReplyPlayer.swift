import Foundation
import XCTest

extension CaptureScreensUITests {
    /// Apple Music の参照と同じ `Reply` を検索結果から選び、歌詞を含むプレイヤー一式を撮る。
    /// 同名曲が複数あるため、API で歌詞登録を確認した並びの個体を使い、画面上でも曲名と歌詞本文を検証する。
    @MainActor
    func captureReplyPlayerScreens() {
        let playerScreens = ["miniplayer", "nowplaying", "lyrics-loading", "lyrics", "queue"]
        selectTab("検索")
        let searchField = searchFieldElement
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Reply の親アルバムを検索する欄が表示されなかった")
            skippedScreens += playerScreens
            return
        }
        // 途中で失敗しても、後続の検索画面は必ず未入力かつ player を閉じた状態から始める。
        defer { cleanupReplyCapture(searchField: searchField) }
        guard openCosmicAlbum() != nil else {
            XCTFail("Reply の exact parent album を開けなかった")
            skippedScreens += playerScreens
            return
        }
        let replyTrack = app.buttons["album.track.\(Self.replyItemID)"]
        // アルバム詳細のトラック一覧は遅延生成のため、初期表示範囲外の行は存在すらしない。
        // waitForExistence だけでは永遠に現れないので、スクロールしながら存在を待つ。
        var scrollAttempts = 0
        while !replyTrack.exists, scrollAttempts < 8 {
            app.swipeUp()
            scrollAttempts += 1
        }
        guard replyTrack.waitForExistence(timeout: 10) else {
            XCTFail("親アルバム内の exact Reply track が見つからなかった")
            skippedScreens += playerScreens
            return
        }
        replyTrack.tap()

        // ミニプレイヤーの複合ラベルに曲名と操作を同時に要求し、検索結果や以前の再生状態を誤認しない。
        let openPlayer = app.buttons["Reply, Open Player"]
        let miniPlayerPause = app.buttons["miniplayer.play-pause"]
        guard openPlayer.waitForExistence(timeout: 40), miniPlayerPause.waitForExistence(timeout: 10),
            miniPlayerPause.label == "Pause", isRunning
        else {
            XCTFail("Reply のミニプレイヤーと一時停止状態を確認できなかった")
            skippedScreens += playerScreens
            return
        }
        guard openPlayer.exists else {
            XCTFail("Reply のミニプレイヤーを開けなかった")
            skippedScreens += playerScreens
            return
        }
        settle()
        capture("miniplayer")

        openPlayer.tap()
        let lyricsButton = element(.button, "歌詞")
        guard lyricsButton.waitForExistence(timeout: 10) else {
            XCTFail("Reply のフルプレイヤーが表示されなかった")
            skippedScreens += playerScreens.dropFirst()
            return
        }
        // 同名要素を総当たりすると XCUITest が稀に終了するため、プレイヤー側の固定 ID だけを検証する。
        let playerReplyTitle = app.staticTexts["nowplaying.title"]
        guard playerReplyTitle.waitForExistence(timeout: 10), playerReplyTitle.label == "Reply" else {
            XCTFail("フルプレイヤーのヘッダーが Reply ではなかった")
            skippedScreens += playerScreens.dropFirst()
            return
        }
        settle()
        capture("nowplaying")

        let playerPause = firstHittableElement(in: app.buttons.matching(identifier: "Pause"), timeout: 10)
        guard let playerPause else {
            XCTFail("Reply のフルプレイヤーを一時停止できなかった")
            skippedScreens += ["lyrics-loading", "lyrics", "queue"]
            return
        }
        playerPause.tap()
        lyricsButton.tap()
        // 通信中ではなく、同期歌詞を読み込んで先頭時刻より前に置いた安定状態を loading 参照へ使う。
        let introPlaceholder = app.staticTexts["lyrics.intro-placeholder"]
        let seekBar = app.otherElements.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Playback Position", "再生位置")
        ).firstMatch
        guard seekBar.waitForExistence(timeout: 10) else {
            XCTFail("Reply の再生位置を 0:00 に戻す slider が見つからなかった")
            skippedScreens += ["lyrics-loading", "lyrics", "queue"]
            return
        }
        var seekAttempts = 0
        while seekBar.value as? String != "0:00", seekAttempts < 3 {
            // SwiftUI の独自 adjustable 要素は XCUI の slider API を受けないため、
            // 実際のシークバー先頭へ短いドラッグを送り、アプリと同じ gesture 経路で戻す。
            let start = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let beginning = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: beginning)
            seekAttempts += 1
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        guard seekBar.value as? String == "0:00", introPlaceholder.waitForExistence(timeout: 20),
            introPlaceholder.isSelected, playerReplyTitle.exists
        else {
            XCTFail("Reply を 0:00 に置いた selected placeholder を表示できなかった")
            skippedScreens += ["lyrics-loading", "lyrics", "queue"]
            return
        }
        settle()
        capture("lyrics-loading")
        // 同期歌詞は行タップでシークできる Button として公開される。
        let lyricLine = app.buttons.matching(
            NSPredicate(format: "label == %@", "瞳映る 静かな世界 なにを見てたんだろう")
        ).firstMatch
        let unavailable = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Lyrics Not Available", "No Lyrics")
        ).firstMatch
        guard lyricLine.waitForExistence(timeout: 20), !unavailable.exists else {
            XCTFail("Reply の実歌詞が表示されなかった")
            skippedScreens += ["lyrics", "queue"]
            return
        }
        lyricLine.tap()
        let selectedLyric = expectation(
            for: NSPredicate(format: "isSelected == true"), evaluatedWith: lyricLine
        )
        guard XCTWaiter.wait(for: [selectedLyric], timeout: 5) == .completed else {
            XCTFail("Reply の既知行へシークして選択状態を確認できなかった")
            skippedScreens += ["lyrics", "queue"]
            return
        }
        XCTAssertTrue(playerReplyTitle.exists, "歌詞表示中の曲名が Reply ではない")
        settle()
        capture("lyrics")

        // 歌詞 2 枚を撮り終えてからだけ参照の 0:55 再生状態へ移し、歌詞 loading の前提を壊さない。
        let seekStart = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.001, dy: 0.5))
        let queuePosition = seekBar.coordinate(withNormalizedOffset: CGVector(dx: 0.2045, dy: 0.5))
        seekStart.press(forDuration: 0.05, thenDragTo: queuePosition)
        guard waitForSeekValue(seekBar, seconds: 55, tolerance: 2, timeout: 5) else {
            XCTFail("Queue 撮影前の Reply を約 0:55 へシークできなかった")
            skippedScreens.append("queue")
            return
        }
        let resume = firstHittableElement(in: app.buttons.matching(identifier: "Play"), timeout: 10)
        guard let resume else {
            XCTFail("Queue 撮影前に Reply を再開できなかった")
            skippedScreens.append("queue")
            return
        }
        resume.tap()
        element(.button, "次に再生").tap()

        let sharedTitle = app.staticTexts["nowplaying.title"]
        let upcomingRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "queue.upcoming."))
        let firstUpcoming = upcomingRows.element(boundBy: 0)
        let secondUpcoming = upcomingRows.element(boundBy: 1)
        guard sharedTitle.waitForExistence(timeout: 10), sharedTitle.label == "Reply",
            sharedTitle.value as? String == Self.replyItemID,
            firstUpcoming.waitForExistence(timeout: 10),
            secondUpcoming.waitForExistence(timeout: 10),
            firstUpcoming.identifier == "queue.upcoming.\(Self.rayItemID)",
            secondUpcoming.identifier == "queue.upcoming.\(Self.meltItemID)",
            firstUpcoming.label.localizedCaseInsensitiveContains("ray"),
            secondUpcoming.label.localizedCaseInsensitiveContains("メルト")
        else {
            XCTFail("Queue が exact Reply → Ray → Melt のアルバム順ではなかった")
            skippedScreens.append("queue")
            return
        }

        // Queue を開くまでの経過時間を捨て、撮影直前に参照の 0:55 へ置き直す。
        guard let pause = firstHittableElement(in: app.buttons.matching(identifier: "Pause"), timeout: 5)
        else {
            XCTFail("Queue 撮影前に再生中の Reply を一時停止できなかった")
            skippedScreens.append("queue")
            return
        }
        pause.tap()
        seekStart.press(forDuration: 0.05, thenDragTo: queuePosition)
        guard waitForSeekValue(seekBar, seconds: 55, tolerance: 2, timeout: 5) else {
            XCTFail("Queue を開いた後に Reply を約 0:55 へ再シークできなかった")
            skippedScreens.append("queue")
            return
        }
        guard let finalResume = firstHittableElement(in: app.buttons.matching(identifier: "Play"), timeout: 5)
        else {
            XCTFail("Queue 撮影直前に Reply を再開できなかった")
            skippedScreens.append("queue")
            return
        }
        finalResume.tap()

        guard firstHittableElement(in: app.buttons.matching(identifier: "Pause"), timeout: 5) != nil
        else {
            XCTFail("Queue 撮影に必要な再生状態が揃わなかった")
            skippedScreens.append("queue")
            return
        }
        capture("queue")
    }

    /// ID を直接指定して Jellyfin item を照合する。撮影対象の親子関係を表示名から推測しない。
    func apiItem(id: String) -> APISearchResult.Item? {
        guard let baseURL = URL(string: serverURL) else { return nil }
        let deviceID = UUID().uuidString
        let baseAuthorization =
            #"MediaBrowser Client="Musicfin", Device="iOS Simulator", DeviceId="\#(deviceID)", Version="0.1.0""#
        var authentication = URLRequest(url: baseURL.appending(path: "/Users/AuthenticateByName"))
        authentication.httpMethod = "POST"
        authentication.setValue(baseAuthorization, forHTTPHeaderField: "Authorization")
        authentication.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authentication.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        guard let (data, response) = synchronousData(for: authentication),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let session = try? JSONDecoder().decode(APIAuthentication.self, from: data)
        else { return nil }

        var components = URLComponents(url: baseURL.appending(path: "/Items"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "userId", value: session.user.id),
            URLQueryItem(name: "ids", value: id),
            URLQueryItem(name: "fields", value: "ParentId"),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(baseAuthorization + #", Token="\#(session.accessToken)""#, forHTTPHeaderField: "Authorization")
        guard let (itemData, itemResponse) = synchronousData(for: request),
            (itemResponse as? HTTPURLResponse)?.statusCode == 200,
            let result = try? JSONDecoder().decode(APISearchResult.self, from: itemData)
        else { return nil }
        return result.items.first
    }

    func replyItem() -> APISearchResult.Item? {
        apiItem(id: Self.replyItemID)
    }

    private func apiSearch(query: String) -> APISearchResult? {
        guard let baseURL = URL(string: serverURL) else { return nil }
        let deviceID = UUID().uuidString
        let baseAuthorization =
            #"MediaBrowser Client="Musicfin", Device="iOS Simulator", DeviceId="\#(deviceID)", Version="0.1.0""#
        var authentication = URLRequest(url: baseURL.appending(path: "/Users/AuthenticateByName"))
        authentication.httpMethod = "POST"
        authentication.setValue(baseAuthorization, forHTTPHeaderField: "Authorization")
        authentication.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authentication.httpBody = try? JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        guard let (authenticationData, authenticationResponse) = synchronousData(for: authentication),
            (authenticationResponse as? HTTPURLResponse)?.statusCode == 200,
            let session = try? JSONDecoder().decode(APIAuthentication.self, from: authenticationData)
        else { return nil }

        var components = URLComponents(url: baseURL.appending(path: "/Items"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "userId", value: session.user.id),
            URLQueryItem(name: "fields", value: "PrimaryImageAspectRatio,ParentId,Genres,ChildCount"),
            URLQueryItem(name: "searchTerm", value: query),
            URLQueryItem(name: "includeItemTypes", value: "Audio,MusicAlbum,MusicArtist,Playlist"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "limit", value: "40"),
        ]
        guard let url = components?.url else { return nil }
        var search = URLRequest(url: url)
        search.setValue(baseAuthorization + #", Token="\#(session.accessToken)""#, forHTTPHeaderField: "Authorization")
        guard let (searchData, searchResponse) = synchronousData(for: search),
            (searchResponse as? HTTPURLResponse)?.statusCode == 200,
            let result = try? JSONDecoder().decode(APISearchResult.self, from: searchData)
        else { return nil }
        return result
    }

    /// XCTest の同期フローから API を照合するため、短い URLSession 処理だけを待つ。
    private func synchronousData(for request: URLRequest) -> (Data, URLResponse)? {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var output: (Data, URLResponse)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, let response { output = (data, response) }
            semaphore.signal()
        }.resume()
        return semaphore.wait(timeout: .now() + 20) == .success ? output : nil
    }

    /// Reply 撮影の成否にかかわらず sheet と検索語を片付け、後続の検索キャプチャを独立させる。
    @MainActor
    private func cleanupReplyCapture(searchField: XCUIElement) {
        if element(.button, "歌詞").exists {
            if isIPadCapture {
                app.swipeDown()
                _ = searchField.waitForExistence(timeout: 10)
            } else {
                // Queue の List が外側の ScrollView に入れ子のままだと、閉じるドラッグが
                // システムの対話的終了ではなく List のスクロールとして吸収されてしまう。
                // アートワークへ戻ってから閉じれば、入れ子のスクロール可能な内容が無くなる。
                let returnToArtwork = element(.button, "アートワークへ戻る")
                // 一時診断: DISMISS_DEBUG。原因特定後に削除する
                print("DISMISS_DEBUG cleanupReplyCapture: returnToArtwork.exists=\(returnToArtwork.exists)")
                if returnToArtwork.exists {
                    returnToArtwork.tap()
                    settle()
                    // 一時診断: DISMISS_DEBUG。mode が .queue から戻っていない可能性の傍証
                    let stillShowing = element(.button, "アートワークへ戻る").exists
                    print("DISMISS_DEBUG cleanupReplyCapture: settle 後も returnToArtwork.exists=\(stillShowing)")
                }
                // iPhone の検索は新しい scene のルートから撮り直すので、ここで閉じ切れなくても
                // 後続へは持ち越さない。閉じられない事象自体は player 側の課題として別に追う。
                guard dismissSheet(revealing: searchField) else { return }
            }
        }
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Reply 撮影後に検索欄へ戻れなかった")
            return
        }
        if isIPadCapture {
            // iPad はこの method の直後に app を破棄する。query は session 外へ永続化されないため、
            // player が閉じて Search root へ戻れたことを cleanup の完了条件にする。
            return
        }
        searchField.tap()
        let clear = app.buttons["Clear text"]
        if clear.waitForExistence(timeout: 2) {
            clear.tap()
        } else if searchFieldHasEnteredText(searchField) {
            // clear button が無い環境でも、選択範囲を全体へ固定してから一度だけ削除する。
            searchField.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            guard selectAll.waitForExistence(timeout: 2) else {
                XCTFail("Reply の検索語を全選択できなかった")
                return
            }
            selectAll.tap()
            searchField.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while ((searchField.value as? String) ?? "").contains("Reply"), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        XCTAssertFalse(((searchField.value as? String) ?? "").contains("Reply"), "Reply の検索語を消去できなかった")
        dismissKeyboard()
    }

    /// 渡された「再生」からアルバムを再生し、ミニプレイヤー → フルプレイヤー（アートワーク／歌詞／次に再生）を撮る。
    /// ストリーミングが始まらなければ 4 画面まとめてスキップし、後続の検索へ進む。
    @MainActor
    private func capturePlayerScreens(playButton: XCUIElement) {
        let playerScreens = ["miniplayer", "nowplaying", "lyrics-loading", "lyrics", "queue"]
        guard playButton.isEnabled else {
            skippedScreens += playerScreens
            return
        }
        playButton.tap()

        // 再生が始まるとミニプレイヤーの再生ボタンが「一時停止」になる。
        let pause = element(.button, "一時停止")
        guard pause.waitForExistence(timeout: 20), isRunning else {
            skippedScreens += playerScreens
            return
        }
        // ミニプレイヤーはタブバー付属のアクセサリなのでどのタブでも見える。アルバム詳細のまま撮る。
        let openPlayer = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'Open Player'")).firstMatch
        guard openPlayer.waitForExistence(timeout: 10), isRunning else {
            skippedScreens += playerScreens
            return
        }
        settle()
        capture("miniplayer")

        openPlayer.tap()
        // 閉じるボタンは廃止された。下部のモード切替「歌詞」はどのモードでも常に出ていて
        // ミニプレイヤーにもブラウズ画面にも無いため、フルプレイヤー到達の判定に使える。
        let lyricsButton = element(.button, "歌詞")
        guard lyricsButton.waitForExistence(timeout: 10), isRunning else {
            skippedScreens += playerScreens.dropFirst()
            return
        }
        settle()
        capture("nowplaying")
        if isIPadCapture {
            capture("playing")
            return
        }

        guard isRunning else {
            skippedScreens += ["lyrics", "queue"]
            return
        }
        lyricsButton.tap()
        // 読み込み状態は一瞬で終わることがあるため、切替直後に先に残してから安定表示を撮る。
        capture("lyrics-loading")
        settle()
        capture("lyrics")

        guard isRunning else {
            skippedScreens.append("queue")
            return
        }
        element(.button, "次に再生").tap()
        settle()
        capture("queue")

        guard isRunning else { return }
        // 背後はアルバム詳細なので、その「再生」が再び押せるようになったら閉じたとみなす。
        if !dismissSheet(revealing: playButton) {
            skippedScreens.append("nowplaying-dismiss")
        }
    }
}
