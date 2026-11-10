import Foundation
import Testing
@testable import DreamLog

extension FoundationTests {
    func messageJSON(_ id: String, seq: Int, role: String, text: String, state: String = "ok", replyTo: String? = nil, offer: String? = nil) -> String {
        let reply = replyTo.map { "\"\($0)\"" } ?? "null"
        let hint = offer.map { "\"\($0)\"" } ?? "null"
        let context = role == "assistant" ? "[{\"label\": \"DREAM\", \"kind\": \"dream\", \"source_id\": \"d\", \"source_revision\": 1, \"source_date\": \"2026-10-10\", \"available\": true, \"cut_to\": null}]" : "[]"
        return "{\"id\": \"\(id)\", \"seq\": \(seq), \"role\": \"\(role)\", \"text\": \"\(text)\", \"state\": \"\(state)\", \"reply_to\": \(reply), \"offer\": \(hint), \"context\": \(context), \"created_at\": 1760371200000}"
    }
    func conversationJSON(_ messages: [String]) -> Data {
        Data("{\"conversation\": {\"dream_id\": \"d\", \"goal\": null, \"messages\": [\(messages.joined(separator: ","))], \"corrections\": [], \"analysis_withheld\": false}}".utf8)
    }
    func stream(_ events: [(String, String)]) -> Data {
        Data(events.map { "event: \($0.0)\r\ndata: \($0.1)\r\n\r\n" }.joined().utf8)
    }

    @Test func turnStreamsRepliesAndRequestAgainListsTheMessageOnce() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let model = DiscussionModel(dreamId: newID())
        enqueue([(200, conversationJSON([messageJSON("u1", seq: 1, role: "user", text: "Why the lake?")]))])
        await model.load(app)
        // The unanswered last message is offered again after a restart of the app (wiki 4.6.7, discussion logic 1).
        #expect(model.pending?.messageId == "u1" && model.pending?.state == .failed)

        let done = "{\"user_message\": \(messageJSON("u1", seq: 1, role: "user", text: "Why the lake?")), \"message\": \(messageJSON("a1", seq: 2, role: "assistant", text: "It was frozen.", replyTo: "u1", offer: "remember_in_profile"))}"
        enqueue([(200, stream([("start", "{\"user_message_id\": \"u1\", \"context_restarted\": true}"), ("delta", "{\"text\": \"It was \"}"), ("delta", "{\"text\": \"frozen.\"}"), ("done", done)]))])
        await model.requestAgain(app)
        let sent = try #require(lastRequest())
        #expect(sent.url?.path() == "/v1/dreams/\(model.dreamId)/conversation/messages" && sent.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        #expect(sentBody(sent)?["message_id"] as? String == "u1" && sentBody(sent)?["text"] as? String == "Why the lake?")
        #expect(model.conversation?.messages.map(\.id) == ["u1", "a1"] && model.pending == nil && model.streamingText.isEmpty && model.contextRestarted)
        #expect(model.offer?.messageId == "u1" && model.offer?.offer == .rememberInProfile)
        model.answerOffer(app, replyId: "a1")
        #expect(model.offer == nil && app.answeredOffers.contains("a1"))
        await closeJournalApp(app)
    }

    @Test func turnFailuresKeepTheMessageAndOnlyStillWorkingIsNotAFailure() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let model = DiscussionModel(dreamId: newID())
        enqueue([(429, Data("{\"error\":\"cap_reached\",\"message\":\"Daily limit reached.\"}".utf8))])
        await model.send(app, text: "A question")
        #expect(model.pending?.state == .failed && model.turnError?.code == "cap_reached" && model.pending?.text == "A question")

        enqueue([(200, stream([("start", "{\"user_message_id\": \"x\", \"context_restarted\": false}"), ("delta", "{\"text\": \"Half\"}")]))])
        await model.requestAgain(app)
        #expect(model.pending?.state == .failed && model.turnError == .interrupted && model.streamingText.isEmpty)

        enqueue([(200, stream([("start", "{\"user_message_id\": \"x\", \"context_restarted\": false}"), ("error", "{\"error\": \"provider_refused\", \"message\": \"Declined.\", \"request_id\": \"r\"}")]))])
        await model.requestAgain(app)
        #expect(model.turnError?.code == "provider_refused" && turnFailureText(model.turnError!) == "The AI service did not answer this message. Your message is kept, and you can write another.")

        enqueue([(409, Data("{\"error\":\"turn_in_progress\",\"message\":\"Still writing.\"}".utf8))])
        await model.requestAgain(app)
        #expect(model.pending?.state == .stillWorking)

        enqueue([(403, Data("{\"error\":\"not_permitted\",\"message\":\"Discussion is turned off for this dream.\"}".utf8))])
        await model.send(app, text: "Another")
        #expect(model.discussionOff)
        await closeJournalApp(app)
    }

    @Test func staleThreadsAndNotesFromMessages() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let model = DiscussionModel(dreamId: newID())
        enqueue([(200, conversationJSON([messageJSON("u1", seq: 1, role: "user", text: "Hi", state: "stale"), messageJSON("a1", seq: 2, role: "assistant", text: "Hello", state: "stale", replyTo: "u1", offer: "add_to_dream"), messageJSON("u2", seq: 3, role: "user", text: "Again", state: "stale")]))])
        await model.load(app)
        #expect(model.pending == nil && model.replyRemoved && model.offer == nil && !model.canRestart)
        // Remember in profile opens a new note with the message text and no event date; the save is the editor's own.
        let note = NoteEditorModel(id: newID(), newEntry: true, text: "Moved flats last week.")
        #expect(note.value.text == "Moved flats last week." && note.value.eventDate == nil && note.value.eventPrecision == .unknown && note.isEditing)
        await closeJournalApp(app)
    }
}
