import XCTest

// Walks the Skeletal screens against the configured server and keeps a screenshot of each in the test result.
// It adds invented sample dreams and one life note once, so summary, analysis and patterns have something to show.
@MainActor
final class ScreensTests: XCTestCase {
    let samples = [
        ("Rainy bridge", "I waited beside an old stone bridge in the rain, holding my presentation notes, and felt anxious that nobody came."),
        ("Blue bridge", "I crossed a blue bridge over a quiet river. I felt worried at first, then relieved when I reached the other side."),
        ("Night bridge", "At night I stood on a narrow bridge above a dark river and practised my presentation out loud until I felt calm.")
    ]
    func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func refresh(_ app: XCUIApplication) {
        let top = app.collectionViews.firstMatch
        top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.1, thenDragTo: top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        sleep(3)
    }
    func testSkeletalScreens() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        let acknowledge = app.buttons["I acknowledge this notice"]
        if app.navigationBars["Privacy notice"].waitForExistence(timeout: 5) {
            for _ in 0..<5 where !(acknowledge.exists && acknowledge.isHittable) { app.swipeUp() }
            acknowledge.tap()
        }
        XCTAssertTrue(app.buttons["typeDream"].waitForExistence(timeout: 15))
        sleep(2)
        var seeded = false
        app.tabBars.buttons["Life Notes"].tap()
        let note = "Crossing the old bridge on my way to the presentation tomorrow."
        if !app.staticTexts[note].waitForExistence(timeout: 5) {
            app.buttons["addNote"].tap()
            let field = app.textViews["noteText"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap(); field.typeText(note)
            app.buttons["saveNote"].tap()
            XCTAssertTrue(app.staticTexts[note].waitForExistence(timeout: 10))
            app.buttons["Done"].tap()
            seeded = true
        }
        snapshot(app, "S07 Life Notes")
        app.tabBars.buttons["Journal"].tap()
        for (title, text) in samples where !app.staticTexts[title].waitForExistence(timeout: 3) {
            app.buttons["typeDream"].tap()
            let titleField = app.textFields["journalTitle"]
            XCTAssertTrue(titleField.waitForExistence(timeout: 5))
            titleField.tap(); titleField.typeText(title)
            let body = app.textViews["journalText"]
            body.tap(); body.typeText(text)
            app.buttons["Done"].tap()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15))
            seeded = true
        }
        // The server's worker summarizes, analyzes, indexes and matches each dream in the background.
        if seeded { sleep(100) }
        refresh(app)
        snapshot(app, "S01 Journal")
        app.buttons["Filter this journal"].tap()
        snapshot(app, "S01 Journal filters")
        app.buttons["Filter this journal"].tap()

        app.staticTexts["Night bridge"].tap()
        XCTAssertTrue(app.buttons["Edit Dream"].waitForExistence(timeout: 10))
        sleep(3)
        snapshot(app, "S03 Dream Detail 1")
        for page in 2...5 {
            app.swipeUp()
            sleep(1)
            snapshot(app, "S03 Dream Detail \(page)")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.tabBars.buttons["Patterns"].tap()
        sleep(4)
        refresh(app)
        snapshot(app, "S06 Patterns")
        app.swipeUp()
        snapshot(app, "S06 Patterns 2")
        let correct = app.buttons["Correct this pattern"].firstMatch
        if correct.exists {
            if !correct.isHittable { app.swipeUp() }
            correct.tap()
            sleep(1)
            snapshot(app, "S06 Correct this pattern")
            app.swipeUp()
            snapshot(app, "S06 Correct this pattern 2")
        }
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        app.buttons["Garden"].tap()
        sleep(1)
        snapshot(app, "S10 Garden")

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        snapshot(app, "S08 Settings")
        app.buttons["Done"].tap()
    }
}
