import XCTest

@MainActor
final class TagLibraryTests: XCTestCase {
    func testOverlayCreatesSelectsRenamesAndDeletesTags() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let acknowledge = app.buttons["I acknowledge this notice"]
        if app.staticTexts["Privacy notice"].waitForExistence(timeout: 3) {
            for _ in 0..<5 where !acknowledge.isHittable { app.swipeUp() }
            acknowledge.tap()
        }
        XCTAssertTrue(app.buttons["tab_journal"].waitForExistence(timeout: 10))
        app.buttons["tab_journal"].tap()
        app.buttons["tab_add"].tap()
        let addTag = app.buttons["addTag"]
        for _ in 0..<4 where !addTag.isHittable { app.swipeUp() }
        XCTAssertTrue(addTag.waitForExistence(timeout: 5))
        addTag.tap()
        let another = app.buttons["addAnotherTag"]
        for _ in 0..<25 where !another.isHittable { app.scrollViews["tagLibraryList"].swipeUp() }
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: another)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let suffix = String(UUID().uuidString.prefix(5))
        let names = ["Ocean", "Calm", "Travel"].map { "\($0) \(suffix)" }
        for name in names {
            for _ in 0..<25 where !another.isHittable { app.scrollViews["tagLibraryList"].swipeUp() }
            another.tap()
            let field = app.alerts.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.typeText(name)
            app.alerts.buttons["Save"].tap()
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Tag library overlay"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["tagLibraryDone"].tap()
        XCTAssertTrue(app.buttons[names[0]].waitForExistence(timeout: 5))
        addTag.tap()
        for _ in 0..<25 where !app.buttons["Manage \(names[0])"].isHittable { app.scrollViews["tagLibraryList"].swipeUp() }
        XCTAssertTrue(app.buttons[names[0]].waitForExistence(timeout: 5))
        app.buttons["Manage \(names[0])"].tap()
        app.buttons["Rename"].tap()
        let renamed = names[0] + " edited"
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: names[0].count) + renamed)
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons[renamed].waitForExistence(timeout: 5))
        for name in [renamed, names[1], names[2]] {
            app.buttons["Manage \(name)"].tap()
            app.buttons["Delete from tag library"].tap()
            app.buttons["Delete tag"].tap()
            XCTAssertTrue(app.buttons[name].waitForNonExistence(timeout: 5))
        }
        app.buttons["tagLibraryDone"].tap()
        // An empty draft is discarded without creating a server dream or scheduling AI.
        app.buttons["Done"].tap()
    }
}
