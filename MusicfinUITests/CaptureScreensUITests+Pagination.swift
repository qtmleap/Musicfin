import XCTest

extension CaptureScreensUITests {
    @MainActor
    func testSongsContinuesPastFirstHundred() {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()
        selectTab("ライブラリ")
        let songs = app.buttons["library.songs"]
        XCTAssertTrue(songs.waitForExistence(timeout: 20))
        songs.tap()
        let rows = app.buttons.matching(identifier: "song.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        var observed = Set<String>()
        for _ in 0..<65 {
            for row in rows.allElementsBoundByIndex where row.isHittable {
                observed.insert(row.label)
            }
            if observed.count > 100 { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertGreaterThan(observed.count, 100, "Songs が最初の 100 曲で止まっていた")
    }

    @MainActor
    func testNewContinuesPastFirstTwenty() {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()
        selectTab("New")
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album.card."))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 30))
        var observed = Set<String>()
        for _ in 0..<24 {
            for card in cards.allElementsBoundByIndex where card.isHittable {
                observed.insert(card.identifier)
            }
            if observed.count > 20 { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertGreaterThan(observed.count, 20, "New が最初の 20 枚で止まっていた")
    }
    @MainActor
    func testHomeContinuesAlbums() {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()
        selectTab("ホーム")
        assertObservedItems(prefix: "home.album.", exceeds: 20)
    }

    @MainActor
    func testLibraryContinuesRecentlyAdded() {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()
        selectTab("ライブラリ")
        let firstPage = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.recent."))
        XCTAssertTrue(firstPage.firstMatch.waitForExistence(timeout: 30))
        XCTAssertLessThanOrEqual(firstPage.count, 20, "画面外の末尾から全件を取得していた")
        assertObservedItems(prefix: "library.recent.", exceeds: 20)
    }

    @MainActor
    func testRadioContinuesPastFirstMix() {
        continueAfterFailure = false
        launchApp()
        ensureSignedIn()
        selectTab("Radio")
        assertObservedItems(prefix: "radio.track.", exceeds: 30)
    }

    @MainActor
    private func assertObservedItems(prefix: String, exceeds count: Int) {
        let elements = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        var observed = Set<String>()
        for _ in 0..<30 {
            for element in elements.allElementsBoundByIndex where element.isHittable {
                observed.insert(element.identifier)
                if observed.count > count { break }
            }
            if observed.count > count { break }
            let loadMore = app.buttons["Load More"]
            if loadMore.isHittable { loadMore.tap() }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertGreaterThan(observed.count, count, "\(prefix) が最初の取得件数で止まっていた")
    }

}
