import Foundation
import Testing
@testable import DreamLog

extension FoundationTests {
    func sentBody(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 { data.append(buffer, count: count) }
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func lastRequest() -> URLRequest? { BackendProtocol.state.withLock { $0.requests.last } }
    func serverDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
    func taskResponse(_ task: TaskInfo) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(["task": task])
    }
    var patternsJSON: Data {
        Data("""
        {"available": true, "period": {"from_date": "2026-09-16", "to_date": "2026-10-15"}, "eligible_dreams": 5, "previous_eligible_dreams": 0,
         "findings": [{"group_id": "g1", "label": null, "label_corrected": false, "kind": "recurring", "status": "refreshing", "explanation": null,
                       "supporting_dreams": 3, "period_count": 3, "previous_count": 0, "trend": "brand_new_trend",
                       "examples": [{"dream_id": "d1", "dream_date": "2026-10-13", "title": null, "category": "action", "description": "missing the bus",
                                     "excerpt": "The bus kept leaving", "shared_element": "a vehicle departing", "difference": null},
                                    {"dream_id": "d1", "dream_date": "2026-10-13", "title": null, "category": "object", "description": "a bus",
                                     "excerpt": "The bus kept leaving", "shared_element": "a vehicle", "difference": null}],
                       "notes": ["Different drivers"], "dismissal_notes": [{"dream_id": "d4", "note": "Different drivers"}]}],
         "insufficient_history": false,
         "task": {"id": "t9", "type": "refresh_findings", "status": "failed", "error_code": "rate_limited", "dream_id": null, "subject_id": null, "source_revision": null, "updated_at": 1760371200000}}
        """.utf8)
    }

    @Test func serverShapesDecodeAndUnknownValuesNeverBreakDecoding() throws {
        let dream = Data("""
        {"dream": {"id": "9f1e", "text": "By the lake.", "revision": 2, "dream_date": "2026-10-12", "title": null, "mood": "calm", "source": "text",
          "audio_status": "none", "audio_ms": null, "heard_text": null,
          "permissions": {"transcription": true, "analysis": true, "discussion": true, "history": true, "patterns": true, "visuals": true},
          "tasks": [{"id": "t1", "type": "organize", "status": "failed", "error_code": "cap_reached", "dream_id": "9f1e", "subject_id": null, "source_revision": 2, "updated_at": 1760371200000},
                    {"id": "t2", "type": "index_dream", "status": "waiting", "error_code": null, "dream_id": "9f1e", "subject_id": null, "source_revision": 2, "updated_at": 1760371200000},
                    {"id": "t3", "type": "future_kind", "status": "paused", "error_code": null, "dream_id": "9f1e", "subject_id": null, "source_revision": 2, "updated_at": 1760371200000}],
          "organization": {"status": "current", "dream_revision": 2, "summary": "A walk by a lake.", "summary_corrected": false,
            "tags": [{"category": "place", "text": "blue lake", "original_text": "lake", "excerpt": "by the lake", "feeling": null, "corrected": true, "removed": false},
                     {"category": "emotion", "text": "calm", "original_text": "calm", "excerpt": "calm", "feeling": "inferred", "corrected": false, "removed": true}],
            "created_at": 1760371200000},
          "created_at": 1760371200000, "updated_at": 1760371200000}}
        """.utf8)
        let value = try serverDecoder().decode(DreamResponse.self, from: dream).dream
        #expect(value.tasks.map(\.type) == [.organize, .indexDream, .unknown])
        #expect(value.tasks[0].limited && value.tasks[1].inProgress && value.tasks[2].status == .unknown)
        #expect(value.organization?.tags.map(\.removed) == [false, true] && value.organization?.tags[1].feeling == .inferred)
        #expect(failureText(value.tasks[0]).contains("resets at \(limitReset())"))

        let analysis = Data("""
        {"analysis": {"id": "c2d4", "status": "outdated", "dream_revision": 2,
          "sections": [{"kind": "waking_life_connections", "text": "The deadline [M1] may echo the rush.", "citations": ["DREAM", "M1"]},
                       {"kind": "new_kind", "text": "Something else.", "citations": ["D9"]}],
          "withheld": 1,
          "context": [{"label": "DREAM", "kind": "dream", "source_id": "9f1e", "source_revision": 2, "source_date": "2026-10-15", "available": true, "cut_to": null},
                      {"label": "DESC", "kind": "output", "source_id": "o1", "source_revision": 1, "source_date": null, "available": false, "cut_to": null},
                      {"label": "M1", "kind": "memory", "source_id": "77aa", "source_revision": 1, "source_date": "2026-10-13", "available": true, "cut_to": 200}],
          "removed_sources": 1, "dream_date": "2026-10-15", "mood": null, "model": "test-model", "instruction_version": "analyze-1", "created_at": 1760371200000},
         "task": null}
        """.utf8)
        let read = try serverDecoder().decode(AnalysisResponse.self, from: analysis)
        let result = try #require(read.analysis)
        let note = "Life note · \(displayDate("2026-10-13"))"
        #expect(result.context.map(\.name) == ["This dream", "This dream's summary and tags", note])
        #expect(result.text(of: result.sections[0]) == "The deadline \(note) may echo the rush.")
        #expect(result.sources(of: result.sections[0]) == ["This dream", note])
        #expect(result.sections[1].kind == .unknown && result.sources(of: result.sections[1]) == ["A source that has since changed"])

        let patterns = try serverDecoder().decode(PatternsResponse.self, from: patternsJSON)
        let finding = try #require(patterns.findings.first)
        #expect(finding.name == "Unnamed theme" && finding.status == .refreshing && finding.trend == .unknown)
        #expect(finding.examples.count == 2 && finding.dreams.map(\.dreamId) == ["d1"])
        #expect(patterns.task?.type == .refreshFindings && patterns.task?.status == .failed)
    }

    @Test func limitResetIsTheNextUTCMidnight() {
        let late = Date(timeIntervalSince1970: 1_760_571_000)
        #expect(limitReset(late) == Date(timeIntervalSince1970: 1_760_572_800).formatted(date: .omitted, time: .shortened))
    }

    @Test func journalLoadSendsQueuedDraftsAndStopsWhileTheServerIsOutOfReach() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        var first = Draft(dreamId: newID(), dreamDate: "2026-10-12")
        first.text = "First invented dream."; first.updatedAt = Date(timeIntervalSince1970: 2000)
        var second = Draft(dreamId: newID(), dreamDate: "2026-10-11")
        second.text = "Second invented dream."; second.updatedAt = Date(timeIntervalSince1970: 1000)
        try await app.store.saveDraft(first).get()
        try await app.store.saveDraft(second).get()
        let failure = Data("{\"error\":\"internal\",\"message\":\"Try again\"}".utf8)
        enqueue([(500, failure), (500, failure)])
        let journal = JournalModel()
        await journal.load(app)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["PUT", "GET"])
        #expect(journal.rows.count == 2 && journal.rows.allSatisfy { $0.status == .unsentDraft })

        BackendProtocol.state.withLock { $0.requests = [] }
        let items = [first, second].map { "{\"id\":\"\($0.dreamId)\",\"dream_date\":\"\($0.dreamDate)\",\"title\":null,\"mood\":null,\"revision\":1,\"audio_status\":\"none\",\"preview\":\"\($0.text)\",\"summary\":null,\"status\":\"processing\",\"favorite_visual_id\":null,\"updated_at\":1}" }
        enqueue([(404, Data("{\"error\":\"not_found\",\"message\":\"Not found\"}".utf8)), (201, try dreamResponse(journalDream(id: first.dreamId, text: first.text))),
                 (201, try dreamResponse(journalDream(id: second.dreamId, text: second.text))), (200, Data("{\"items\":[\(items.joined(separator: ","))],\"has_more\":false}".utf8))])
        await journal.load(app)
        let requests = BackendProtocol.state.withLock { $0.requests }
        // The uncertain first save is read before it is sent again (wiki 4.5.8, "An unconfirmed draft").
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "PUT", "GET"])
        #expect(requests[1].url?.lastPathComponent == first.dreamId && requests[2].url?.lastPathComponent == second.dreamId)
        #expect(try await app.store.drafts().get().isEmpty)
        #expect(journal.rows.map(\.status) == [.processing, .processing] && journal.error == nil)
        await closeJournalApp(app)
    }

    @Test func journalLeavesTheDraftOfAnOpenEditorAlone() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        var draft = Draft(dreamId: newID(), dreamDate: "2026-10-12")
        draft.text = "Being typed."
        try await app.store.saveDraft(draft).get()
        app.editing.insert(draft.dreamId)
        enqueue([(200, Data("{\"items\":[],\"has_more\":false}".utf8))])
        let journal = JournalModel()
        await journal.load(app)
        #expect(BackendProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["GET"])
        #expect(journal.rows.map(\.id) == [draft.dreamId])
        await closeJournalApp(app)
    }

    @Test func dreamScreenActionsSendOneRequestAndShowTheReturnedRecord() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let id = newID()
        var stored = journalDream(id: id)
        let model = DreamModel(id: id)
        enqueue([(200, try dreamResponse(stored))])
        await model.load(app)
        stored.permissions = Permissions(transcription: false, analysis: false, discussion: false, history: false, patterns: false, visuals: false)
        enqueue([(200, try dreamResponse(stored))])
        await model.savePermissions(app, Dictionary(uniqueKeysWithValues: dreamSwitches.map { ($0.key, false) }))
        let keepOut = try #require(lastRequest())
        #expect(keepOut.httpMethod == "PUT" && keepOut.url?.path() == "/v1/dreams/\(id)/permissions")
        #expect((sentBody(keepOut) as? [String: Bool]) == ["transcription": false, "analysis": false, "discussion": false, "history": false, "patterns": false, "visuals": false])
        #expect(model.dream?.permissions.analysis == false && model.draft?.permissions.history == false)

        enqueue([(200, try dreamResponse(stored))])
        await model.correct(app, DreamCorrection(category: "place", originalText: "lake", text: ""))
        let correction = try #require(lastRequest())
        #expect(correction.url?.path() == "/v1/dreams/\(id)/corrections")
        #expect((sentBody(correction) as? [String: String]) == ["category": "place", "original_text": "lake", "text": ""])
        enqueue([(200, try dreamResponse(stored))])
        await model.correct(app, DreamCorrection(category: "summary", text: "Mine."))
        #expect((sentBody(try #require(lastRequest())) as? [String: String]) == ["category": "summary", "text": "Mine."])

        let failed = TaskInfo(id: newID(), type: .organize, status: .failed, errorCode: "cap_reached", updatedAt: .now)
        model.dream?.tasks = [failed]
        var waiting = failed
        waiting.status = .waiting; waiting.errorCode = nil
        enqueue([(200, try taskResponse(waiting))])
        await model.retry(app, task: failed)
        #expect(lastRequest()?.url?.path() == "/v1/tasks/\(failed.id)/retry" && lastRequest()?.httpMethod == "POST")
        #expect(model.dream?.tasks.first?.status == .waiting && model.error == nil)
        await closeJournalApp(app)
    }

    @Test func analysisRefreshWordsTheLimitAndASplitConflictReadsAgain() async throws {
        let (app, identity, defaults, namespace) = try await journalApp()
        defer { _ = identity.delete(); defaults.removePersistentDomain(forName: namespace) }
        let analysis = AnalysisModel(dreamId: newID())
        enqueue([(429, Data("{\"error\":\"cap_reached\",\"message\":\"Daily limit reached.\"}".utf8))])
        await analysis.refresh(app)
        let refresh = try #require(lastRequest())
        #expect(refresh.url?.path() == "/v1/dreams/\(analysis.dreamId)/analysis/refresh")
        #expect((sentBody(refresh)?["refresh_id"] as? String).flatMap(UUID.init(uuidString:)) != nil)
        #expect(analysis.error == "Today's limit for this kind of generation is used up. It resets at \(limitReset()).")

        let patterns = PatternsModel()
        enqueue([(200, patternsJSON)])
        await patterns.load(app)
        let finding = try #require(patterns.response?.findings.first)
        BackendProtocol.state.withLock { $0.requests = [] }
        enqueue([(409, Data("{\"error\":\"invalid_state\",\"message\":\"Already split.\"}".utf8)), (200, patternsJSON)])
        await patterns.split(app, finding, dreamIds: ["d1"], label: "", note: "")
        let requests = BackendProtocol.state.withLock { $0.requests }
        #expect(requests.map(\.httpMethod) == ["POST", "GET"])
        let split = try #require(sentBody(requests[0]))
        #expect(split["dream_ids"] as? [String] == ["d1"] && split["note"] as? String == "" && split["label"] == nil)
        #expect(patterns.error == "Already split." && patterns.response != nil)

        enqueue([(200, patternsJSON)])
        await patterns.rename(app, finding, label: "")
        #expect((sentBody(try #require(lastRequest())) as? [String: String]) == ["label": ""])
        await closeJournalApp(app)
    }
}
