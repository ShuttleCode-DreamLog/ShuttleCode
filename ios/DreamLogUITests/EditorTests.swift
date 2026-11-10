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
        // The title box sits above the text: naming the dream there keeps the AI from naming it.
        let titleField = app.textFields["dreamTitle"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap(); titleField.typeText(title)
        let journalEditor = app.textViews["journalText"]
        journalEditor.tap(); journalEditor.typeText("Original invented dream.")
        XCTAssertFalse(app.buttons["saveJournal"].exists)
        app.buttons["saveDream"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        app.staticTexts[title].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit Dream"].waitForExistence(timeout: 5))
        app.buttons["Edit Dream"].tap()
        XCTAssertTrue(journalEditor.waitForExistence(timeout: 5))
        journalEditor.tap(); journalEditor.typeText(" Discard this edit.")
        // Cancel with an edit asks, like a life note's; Discard drops the edit and closes the editor over the dream's page.
        app.buttons["cancelJournal"].tap()
        app.buttons["Discard"].tap()
        XCTAssertTrue(journalEditor.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit Dream"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original invented dream."].exists)
        XCTAssertFalse(app.staticTexts["Original invented dream. Discard this edit."].exists)
        let deleteDream = app.buttons["Delete Dream"]
        for _ in 0..<10 where !(deleteDream.exists && deleteDream.isHittable) { app.swipeUp() }
        // Delete Dream ends the page; the drawn bar covers the page's last stretch until it is scrolled to the end.
        app.swipeUp()
        deleteDream.tap()
        let confirmDelete = app.sheets.firstMatch.buttons["Delete Dream"]
        if confirmDelete.waitForExistence(timeout: 3) { confirmDelete.tap() } else { app.buttons.matching(identifier: "Delete Dream").element(boundBy: 1).tap() }
        XCTAssertTrue(app.staticTexts["Journal"].waitForExistence(timeout: 10))
    }

    func testTappingOutsideTheTextPutsTheKeyboardAway() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let acknowledge = app.buttons["I acknowledge this notice"]
        if app.staticTexts["Privacy notice"].waitForExistence(timeout: 3) {
            for _ in 0..<4 where !(acknowledge.exists && acknowledge.isHittable) { app.swipeUp() }
            acknowledge.tap()
        }
        XCTAssertTrue(app.buttons["tab_add"].waitForExistence(timeout: 10))
        app.buttons["tab_add"].tap()
        let text = app.textViews["journalText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let editing = { (text.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        text.tap(); text.typeText("Keyboard check")
        XCTAssertTrue(editing())
        app.staticTexts["What do you remember?"].tap()
        XCTAssertFalse(editing())
        // A tap inside the text keeps editing rather than putting the keyboard away again.
        text.tap()
        XCTAssertTrue(editing())
        text.typeText(" again")
        XCTAssertTrue(editing())
        app.buttons["Discard draft"].tap()
        app.buttons["Delete entry"].tap()
        XCTAssertTrue(app.buttons["tab_add"].waitForExistence(timeout: 5))
    }
}
