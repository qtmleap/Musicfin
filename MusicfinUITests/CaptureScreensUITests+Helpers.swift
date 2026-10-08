import Foundation
import XCTest

// MARK: - 補助

extension CaptureScreensUITests {
    /// 検索タブ（`role: .search`）が選ばれている間はタブバーが検索欄に変形して他のタブが消えるので、
    /// まず「閉じる」で元に戻してから目的のタブを押す。
    @MainActor
    func selectTab(_ title: String) {
        let labels = ["ホーム": "Home", "ライブラリ": "Library", "検索": "Search"]
        let localizedTitle = labels[title] ?? title
        if isIPadCapture {
            let routeNames = ["ホーム": "home", "ライブラリ": "library", "検索": "search"]
            let sidebar = padSidebarRow("sidebar.\(routeNames[title] ?? title)")
            guard sidebar.waitForExistence(timeout: 10) else {
                XCTFail("iPad sidebar を選べなかった: \(localizedTitle)")
                return
            }
            sidebar.tap()
            let selected = expectation(
                for: NSPredicate(format: "isSelected == true"), evaluatedWith: sidebar
            )
            _ = XCTWaiter.wait(for: [selected], timeout: 5)
            return
        }
        let tab = app.tabBars.buttons[localizedTitle]
        if !tab.exists {
            let closeSearch = element(.button, "閉じる")
            if closeSearch.exists { closeSearch.tap() }
            if localizedTitle == "Search" {
                // 検索タブを選択している間はタブバーが検索欄に変形し "Search" という
                // 名前のボタン自体が消える。編集中は「閉じる」で片付き、アイドル表示
                // (ジャンル一覧など)では「閉じる」も無いままここに来るが、どちらの
                // 経路でもここに到達した時点で検索タブへの遷移はすでに完了している。
                return
            }
        }
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
            return
        }
        // iPad sidebar は tab bar ではなく通常の Button なので、見えて操作できる同名行を選ぶ。
        if let sidebar = firstHittableElement(
            in: app.buttons.matching(identifier: localizedTitle), timeout: 5
        ) {
            sidebar.tap()
        } else {
            XCTFail("タブを選べなかった: \(localizedTitle)")
        }
    }

    /// sheet を下スワイプで閉じ、背後の要素が押せる状態に戻るまで待つ。
    /// 閉じられなくても無限に粘らず、呼び出し側が次へ進めるよう成否だけ返す。
    @MainActor
    func dismissSheet(revealing target: XCUIElement, attempts maxAttempts: Int = 3) -> Bool {
        var attempts = 0
        while !target.isHittable, attempts < maxAttempts, isRunning {
            // 一時診断: DISMISS_DEBUG。原因特定後に削除する
            print("DISMISS_DEBUG dismissSheet: attempt=\(attempts)")
            // sheet の上端を掴んで下まで引く。中央からの swipeDown では中身がスクロールするだけで閉じない。
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            start.press(forDuration: 0.05, thenDragTo: end)
            settle()
            attempts += 1
        }
        // 一時診断: DISMISS_DEBUG。原因特定後に削除する
        print("DISMISS_DEBUG dismissSheet: ループ終了 attempts=\(attempts) target.isHittable=\(target.isHittable)")
        return target.isHittable
    }

    /// iPhone の tab search と iPad detail の searchable が公開する型差を吸収する。
    @MainActor
    var searchFieldElement: XCUIElement {
        let search = app.searchFields.firstMatch
        if search.exists { return search }
        return app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@ OR placeholderValue == %@",
                "Artists, Songs, Lyrics, and More", "アーティスト、曲、歌詞など")
        ).firstMatch
    }

    /// 一覧の絞り込み欄。iPad は `librarySearchable` が `UISearchTextField` を自前で置くので
    /// `searchFields` には現れず、`app.searchFields.firstMatch` では掴めない（仕様 6 章）。
    @MainActor
    var listSearchField: XCUIElement {
        let search = app.searchFields.firstMatch
        if search.exists { return search }
        return app.textFields.matching(
            NSPredicate(
                format: "placeholderValue == %@ OR placeholderValue == %@", "Search", "検索")
        ).firstMatch
    }

    /// 検索欄の現在の入力。placeholder は value に混ざるので、その状態は空として返す。
    @MainActor
    func enteredText(of field: XCUIElement) -> String {
        guard let value = field.value as? String, value != field.placeholderValue else { return "" }
        return value
    }

    /// 検索語を確実に入れる。1 文字目で入力前の画面が結果一覧へ切り替わると検索欄の focus が外れ、
    /// `typeText` の残りが丸ごと落ちる（実測では「Ray」が「R」になった）。
    /// 入力後の value を見て、足りない分だけ焦点を取り直して打ち足す。
    @MainActor
    @discardableResult
    func typeSearchQuery(_ field: XCUIElement, _ query: String) -> Bool {
        for _ in 0..<query.count + 4 {
            let current = enteredText(of: field)
            if current == query { return true }
            guard query.hasPrefix(current) else {
                // 別の語が残っている状態から打ち足すと混ざるので、消してから入れ直す。
                field.tap()
                let clear = app.buttons["Clear text"]
                if clear.exists { clear.tap() }
                continue
            }
            field.tap()
            field.typeText(String(query.dropFirst(current.count)))
        }
        return enteredText(of: field) == query
    }

    /// 未入力時の `value` は空文字ではなく placeholder になるので、その状態を検索語と誤認しない。
    @MainActor
    func searchFieldHasEnteredText(_ field: XCUIElement) -> Bool {
        guard let value = field.value as? String else { return false }
        return !value.isEmpty
            && value != "Artists, Songs, Lyrics, and More"
            && value != "アーティスト、曲、歌詞など"
    }

    /// シークバーが公開する m:ss を秒へ戻し、参照時刻へ着地したことを待つ。
    @MainActor
    func waitForSeekValue(
        _ element: XCUIElement, seconds: Int, tolerance: Int, timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let value = element.value as? String {
                let parts = value.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2, abs(parts[0] * 60 + parts[1] - seconds) <= tolerance {
                    return true
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        return false
    }

    /// query の中から実際に操作可能な要素を探す。背後に残る同名要素を誤認しないために使う。
    @MainActor
    func firstHittableElement(in query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            for index in 0..<query.count {
                let candidate = query.element(boundBy: index)
                if candidate.exists, candidate.isHittable { return candidate }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return nil
    }

    /// 複数の要素のどれかが現れるまで待つ。起動直後の分岐に使う。
    @MainActor
    func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return elements.contains(where: { $0.exists })
    }

    /// 要素が消えるまで待つ。同じ文言のボタンが遷移元にもある画面で、遷移の成否を確かめるのに使う。
    @MainActor
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        }
        return !element.exists
    }

    /// キーボードに隠れているときはスクロールして押せる位置に出す。
    @MainActor
    func tapScrollingIntoView(_ element: XCUIElement) {
        var attempts = 0
        while !element.isHittable, attempts < 4 {
            app.swipeUp()
            attempts += 1
        }
        element.tap()
    }

    /// シミュレータ初回のキーボード説明（Continue）が出ていれば閉じる。出たままだと入力が届かない。
    @MainActor
    func dismissKeyboardTutorial() {
        let tutorialContinue = element(.button, "Continue")
        if tutorialContinue.waitForExistence(timeout: 1) { tutorialContinue.tap() }
    }

    /// 撮影対象がキーボードに隠れないよう、出ていれば閉じる（各画面は interactive dismiss 対応）。
    @MainActor
    func dismissKeyboard() {
        dismissKeyboardTutorial()
        guard app.keyboards.firstMatch.exists else { return }
        // interactive dismiss は指がキーボード領域まで入ったときに閉じるので、単純な swipeDown では足りない。
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.1, thenDragTo: end)
        settle()
        guard app.keyboards.firstMatch.exists else { return }
        // 検索結果の一覧は interactive dismiss に応じないので、閉じられないまま結果の下半分が
        // キーボードに隠れる。iPad のソフトキーボード右下にある格納キーなら確実に閉じられる。
        let hide = app.keyboards.buttons.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "hide keyboard",
                "キーボードを閉じる")
        ).firstMatch
        if hide.exists {
            hide.tap()
            settle()
        }
    }
}
