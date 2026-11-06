import XCTest

@MainActor
final class EditorTests: XCTestCase {
    private func inlineField(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (elementType == %d OR elementType == %d)",
            identifier, XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue
        )).firstMatch
    }
    func testUnifiedInlineEditingAndSave() {
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
        let noteBody = app.staticTexts["noteText"]
        noteBody.doubleTap()
        XCTAssertFalse(inlineField(app, "noteText").exists)
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["editingIndicator"].waitForExistence(timeout: 3))
        XCTAssertFalse(inlineField(app, "noteText").exists)
        noteBody.doubleTap()
        let inlineNote = inlineField(app, "noteText")
        XCTAssertTrue(inlineNote.waitForExistence(timeout: 3))
        inlineNote.typeText(" Updated.")
        app.staticTexts["editablePageTitle"].doubleTap()
        let noteTitle = inlineField(app, "editablePageTitle")
        XCTAssertTrue(noteTitle.waitForExistence(timeout: 3))
        noteTitle.typeText("Edited life note")
        app.buttons["saveNote"].tap()
        XCTAssertTrue(app.staticTexts[noteText + " Updated."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["editingIndicator"].exists)
        XCTAssertTrue(app.staticTexts["Edited life note"].exists)
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
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        app.staticTexts[title].firstMatch.tap()
        let editSave = app.buttons["editSaveDream"]
        XCTAssertTrue(editSave.waitForExistence(timeout: 5))
        let original = app.staticTexts["Original invented dream."]
        original.doubleTap()
        XCTAssertFalse(inlineField(app, "journalText").exists)
        editSave.tap()
        XCTAssertEqual(editSave.label, "Save")
        XCTAssertTrue(app.descendants(matching: .any)["editingIndicator"].waitForExistence(timeout: 3))
        XCTAssertFalse(inlineField(app, "journalText").exists)
        original.doubleTap()
        let inlineDream = inlineField(app, "journalText")
        XCTAssertTrue(inlineDream.waitForExistence(timeout: 3))
        inlineDream.typeText(" Updated.")
        app.staticTexts[title].doubleTap()
        let inlineTitle = inlineField(app, "editablePageTitle")
        XCTAssertTrue(inlineTitle.waitForExistence(timeout: 3))
        inlineTitle.typeText(" renamed")
        editSave.tap()
        XCTAssertTrue(app.staticTexts["Original invented dream. Updated."].waitForExistence(timeout: 10))
        XCTAssertEqual(editSave.label, "Edit")
        XCTAssertFalse(app.descendants(matching: .any)["editingIndicator"].exists)
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts[title + " renamed"].waitForExistence(timeout: 10))
        app.staticTexts[title + " renamed"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Original invented dream. Updated."].waitForExistence(timeout: 10))
        let deleteDream = app.buttons["Delete Dream"]
        for _ in 0..<10 where !(deleteDream.exists && deleteDream.isHittable) { app.swipeUp() }
        // Delete Dream ends the page; the drawn bar covers the page's last stretch until it is scrolled to the end.
        app.swipeUp()
        deleteDream.tap()
        let confirmDelete = app.sheets.firstMatch.buttons["Delete Dream"]
        if confirmDelete.waitForExistence(timeout: 3) { confirmDelete.tap() } else { app.buttons.matching(identifier: "Delete Dream").element(boundBy: 1).tap() }
        XCTAssertTrue(app.staticTexts["Journal"].waitForExistence(timeout: 10))
    }
}
