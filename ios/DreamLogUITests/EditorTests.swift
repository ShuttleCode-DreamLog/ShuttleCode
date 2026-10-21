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
        XCTAssertTrue(app.tabBars.buttons["Life notes"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Life notes"].tap()
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

        app.tabBars.buttons["Journal"].tap()
        app.buttons["typeDream"].tap()
        let title = "UI dream \(UUID().uuidString)"
        let titleField = app.textFields["journalTitle"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap(); titleField.typeText(title)
        let journalEditor = app.textViews["journalText"]
        journalEditor.tap(); journalEditor.typeText("Original invented dream.")
        XCTAssertFalse(app.buttons["saveJournal"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        // A dream dated today is also the Journal's latest-dream card, so its title appears twice.
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
        // The detail list builds rows lazily, so Delete Dream exists only once it is scrolled into view.
        let deleteDream = app.buttons["Delete Dream"]
        for _ in 0..<10 where !(deleteDream.exists && deleteDream.isHittable) { app.swipeUp() }
        deleteDream.tap()
        let confirmDelete = app.sheets.firstMatch.buttons["Delete Dream"]
        if confirmDelete.waitForExistence(timeout: 3) { confirmDelete.tap() } else { app.buttons.matching(identifier: "Delete Dream").element(boundBy: 1).tap() }
        XCTAssertTrue(app.buttons["typeDream"].waitForExistence(timeout: 10))
    }
}
