# Editor behavior, note photos and AI integration points

This records the user's 9 October 2026 changes to the CRUD foundation and supersedes the earlier Journal Save-button design.

## Journal

Typing persists the local draft. Leaving the editor with Done automatically submits valid changed content; leaving the screen or moving the app out of the active state also attempts submission. There is no Journal Save button. An unchanged entry is not submitted again. This avoids a request for every keystroke and needs no timer/debounce layer.

Revert restores the loaded stored entry and removes its local changes. For a new unsaved entry it clears the draft. It is a choice before the editing session is committed, not a rollback of old revisions after reopening. A save whose result is uncertain is checked before Revert discards anything. Conflicts do not overwrite the stored entry. On an explicit Done failure the editor stays open, shows the error and retains the durable draft.

Use `DreamModel.close()` for the default commit and `DreamModel.revert()` to abandon changes. The UI hides the ordinary Back button while editing, offers Done and Revert, and still flushes on disappearance/backgrounding. Journal and Notes present new editors using `.sheet(item:)` with an `EntryRoute`; the UUID is part of the presented value, rather than an independently updated boolean and string. This removes the first-presentation empty-ID risk that model-only tests did not cover.

## Notes and photos

Notes retain an explicit Save action. Select images using the native PhotosPicker, then Save to create/update the note and upload its pending photos. A note may contain photos without text. Unsent note/photo input stays in the open editor. Done offers Save and close, Discard, and Keep editing. Save and close dismisses only after the text and every pending photo have been saved.

Save returns an explicit success result. A new editor can save before its initial load task runs; an editor already associated with an old journal must never attach itself to a replacement identity. Failed saves show an alert even if the form's inline error is offscreen, retain input and leave the editor open. A successful Save switches to the stored detail with Edit available. This remains server persistence: launching the iOS app alone does not launch the local backend.

The app re-encodes selected images as JPEG, at most 1600 pixels on the longest side, to bound storage and omit original location metadata. Each note holds at most 5 photos; each uploaded image is at most 5 MB. The picker accepts images only. Existing photos are downloaded with the same authenticated APIClient and displayed in the detail screen; individual photos can be removed after confirmation. They are not sent to AI.

Photo IDs are generated before upload and retained on failure. The note text is saved first, then photos are uploaded sequentially. If a later upload fails, already-saved text/photos remain, pending images stay in the editor, and retry uses the same IDs. There is no multi-request transaction or hidden successful-save claim. Separate uploads keep JSON bodies small and make collaborator clients simple.

Backend schema version 3 adds `memory_photos`. For this small proof of concept, bytes are a SQLite BLOB and ownership is stored alongside the note ID. Foreign keys delete photos atomically when a note or whole user is deleted. This deliberately differs from the wiki's file storage for generated media: note attachments are a new feature, and using the same database avoids a second file-cleanup protocol. Existing version 1/2 records are preserved. The phone draft schema is unchanged.

If a future release needs many large images, document a migration to private file/object storage while preserving these HTTP paths and metadata fields; mobile clients should not change.

## Callable photo contract

`/v1/memories/{memory_id}/photos/{photo_id}` supports:

| Method | Body / result |
| --- | --- |
| PUT | Raw JPEG/PNG bytes with image/jpeg or image/png. 201 new, 200 retry/update; returns `{"photo":{"id":"…","content_type":"image/jpeg","byte_count":123,"created_at":123}}` |
| GET | Raw image bytes with the stored content type; authenticated and Cache-Control: no-store |
| DELETE | 204; missing or foreign-owned photo returns 404 |

Memory detail/save/list objects include a `photos` array with those metadata objects. Empty notes can be created with text `""` before attaching a photo; the app requires either text or a photo before offering Save. Whitespace-only text is rejected. Upload validates basic JPEG/PNG framing and size; it does not perform server-side image decoding. A photo ID already used for another note cannot be moved or overwritten. See [API.md](API.md).

## Explicit future API space

The code has searchable `AI integration point` comments, rather than empty services or callable fake endpoints:

- `backend/dreams.py`, inside `save_dream` after persistence: enqueue work keyed by owner, dream ID and saved revision in the same transaction. Actual provider API calls belong in the future worker after commit; recheck current revision and permissions before storing results. Repeated saves and automatic commits must not duplicate processing.
- `ios/DreamLog/APIClient.swift`, beside `saveDream`: add task/status or explicit processing-request methods here when their real backend handlers exist. The app must not call an AI provider directly or hold provider credentials.
- `backend/memories.py`, inside `save_memory`: add dependency invalidation for changed/removed memory context before enabling the future analysis pipeline.

There is no processing route or provider call in this build. Future implementation must follow the wiki's task types, ownership, permission and source-revision rules. Photo attachments are excluded from AI inputs until a separate, documented consent/processing design is added. The comments mark actual implementation locations; they do not introduce a wrapper or stub worker.

## Checks

The DreamLogUI scheme exercises the real first Notes save and Journal default commit/Revert through visible buttons. DreamLogHTTPS checks default commits and photo upload/reopen/remove through the actual local backend. Backend tests cover repeated uploads, ownership, count/size/type limits, cascading deletion and upgrades. Exact run results are recorded in [Verification.md](Verification.md).
