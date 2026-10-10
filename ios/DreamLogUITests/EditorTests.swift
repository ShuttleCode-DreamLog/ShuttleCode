import XCTest

@MainActor
final class EditorTests: XCTestCase {
    func testFirstNoteSaveAndJournalAutomaticSaveAndRevert() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let acknowledge = app.buttons["I acknowledge this notice"]
        if app.navigationBars["Privacy notice"].waitForExistence(timeout: 3) {
            for _ in 0..<4 {
                if acknowledge.exists && acknowledge.isHittable { break }
                app.swipeUp()
            }
            acknowledge.tap()
        }
        XCTAssertTrue(app.tabBars.buttons["Notes"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Notes"].tap()
        app.buttons["New life note"].tap()
        let noteText = "UI sample note \(UUID().uuidString)"
        let noteEditor = app.textViews["noteText"]
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 5))
        noteEditor.tap(); noteEditor.typeText(noteText)
        let save = app.buttons["saveNote"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts[noteText].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts[noteText].waitForExistence(timeout: 10))
        app.staticTexts[noteText].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        let deleteNote = app.buttons["Delete note"]
        if !deleteNote.isHittable { app.swipeUp() }
        deleteNote.tap()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Delete note"].tap()

        app.buttons["New life note"].tap()
        let secondNote = "Save on Done \(UUID().uuidString)"
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 5))
        noteEditor.tap(); noteEditor.typeText(secondNote)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Save and close"].waitForExistence(timeout: 3))
        app.buttons["Save and close"].tap()
        XCTAssertTrue(app.staticTexts[secondNote].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New life note"].exists)
        app.staticTexts[secondNote].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        if !deleteNote.isHittable { app.swipeUp() }
        deleteNote.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Delete note"].tap()

        app.tabBars.buttons["Journal"].tap()
        app.buttons["New journal entry"].tap()
        let title = "UI dream \(UUID().uuidString)"
        let titleField = app.textFields["journalTitle"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap(); titleField.typeText(title)
        let journalEditor = app.textViews["journalText"]
        journalEditor.tap(); journalEditor.typeText("Original invented dream.")
        XCTAssertFalse(app.buttons["saveJournal"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        app.staticTexts[title].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        journalEditor.tap(); journalEditor.typeText(" Discard this edit.")
        app.buttons["revertJournal"].tap()
        app.buttons["Revert changes"].tap()
        XCTAssertTrue(app.staticTexts["Original invented dream."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Original invented dream. Discard this edit."].exists)
        let deleteEntry = app.buttons["Delete journal entry"]
        if !deleteEntry.isHittable { app.swipeUp() }
        deleteEntry.tap(); app.buttons["Delete entry"].tap()
        XCTAssertTrue(app.buttons["New journal entry"].waitForExistence(timeout: 5))
    }
}
