import XCTest

@MainActor
final class EditorTests: XCTestCase {
    func testFirstNoteSaveAndJournalAutomaticSaveAndRevert() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let acknowledge = app.buttons["I acknowledge this notice"]
        if app.staticTexts["Privacy notice"].waitForExistence(timeout: 3) {
            for _ in 0..<4 {
                if acknowledge.exists && acknowledge.isHittable { break }
                app.swipeUp()
            }
            acknowledge.tap()
        }
        XCTAssertTrue(app.buttons["tab_notes"].waitForExistence(timeout: 10))
        app.buttons["tab_notes"].tap()
        app.buttons["addNote"].tap()
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

        app.buttons["addNote"].tap()
        let secondNote = "Save on Done \(UUID().uuidString)"
        XCTAssertTrue(noteEditor.waitForExistence(timeout: 5))
        noteEditor.tap(); noteEditor.typeText(secondNote)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Save and close"].waitForExistence(timeout: 3))
        app.buttons["Save and close"].tap()
        XCTAssertTrue(app.staticTexts[secondNote].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["addNote"].exists)
        app.staticTexts[secondNote].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        if !deleteNote.isHittable { app.swipeUp() }
        deleteNote.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Delete note"].tap()

        app.buttons["tab_journal"].tap()
        app.buttons["tab_add"].tap()
        let title = "UI dream \(UUID().uuidString)"
        // The title lives in the header: tap it to name the dream before the first sentence names it.
        let titleButton = app.buttons["dreamTitle"]
        XCTAssertTrue(titleButton.waitForExistence(timeout: 5))
        titleButton.tap()
        let titleField = app.alerts.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        titleField.typeText(title)
        app.alerts.buttons["Save"].tap()
        let journalEditor = app.textViews["journalText"]
        journalEditor.tap(); journalEditor.typeText("Original invented dream.")
        XCTAssertFalse(app.buttons["saveJournal"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit Dream"].waitForExistence(timeout: 5))
        app.buttons["Edit Dream"].tap()
        XCTAssertTrue(journalEditor.waitForExistence(timeout: 5))
        journalEditor.tap(); journalEditor.typeText(" Discard this edit.")
        app.buttons["revertJournal"].tap()
        app.buttons["Revert changes"].tap()
        XCTAssertTrue(app.staticTexts["Original invented dream."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Original invented dream. Discard this edit."].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Edit Dream"].waitForExistence(timeout: 5))
        let deleteDream = app.buttons["Delete Dream"]
        for _ in 0..<10 where !(deleteDream.exists && deleteDream.isHittable) { app.swipeUp() }
        deleteDream.tap()
        let confirmDelete = app.sheets.firstMatch.buttons["Delete Dream"]
        if confirmDelete.waitForExistence(timeout: 3) { confirmDelete.tap() } else { app.buttons.matching(identifier: "Delete Dream").element(boundBy: 1).tap() }
        XCTAssertTrue(app.staticTexts["Journal"].waitForExistence(timeout: 10))
    }
}
