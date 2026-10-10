# Text journal — Increment 1

Implemented after Foundation, following the project wiki §4.5. This milestone uses the existing native SwiftUI app and Starlette/Granian HTTPS backend. It requires no cloud account or AI service call.

## Use

1. Start the backend and simulator using [LocalDevelopment.md](LocalDevelopment.md), then acknowledge the privacy notice.
2. Open Journal and tap **+**. Enter text, an optional title, date and optional mood. **Done** closes the editor and automatically saves changes; failed saves retain the local draft.
3. Tap an entry to read its full text. **Edit** changes it; **Done** commits automatically and **Revert** abandons the current edit. This interaction update is documented in [EditorAndPhotos.md](EditorAndPhotos.md).
4. Use **Delete journal entry**, then confirm **Delete entry**, to delete that entry. An unsent new draft offers **Discard draft**. Settings → **Delete my journal** still deletes the entire journal and identity.
5. Submit the search field to search stored titles and text. The list loads additional pages as needed. Unsent drafts remain visible separately from server search results.

Text must contain something other than whitespace. The limits are 20,000 Unicode scalars for text and 120 for titles, shared with the backend. Older oversized entries may be shortened. The interface is in English; entered text can use any language.

## Implementation locations

| Location | Responsibility |
| --- | --- |
| `backend/dreams.py` | Ownership checks, validation, atomic save, revisions, pagination, search and deletion |
| `backend/main.py`, `web.py` | Route registration and structured revision-conflict errors |
| `ios/DreamLog/JournalView.swift`, `JournalModel.swift` | Journal list, search, pagination and draft/server row merging |
| `ios/DreamLog/DreamEditor.swift`, `DreamModel.swift` | Text entry, reading, editing, save recovery, conflict choices and deletion |
| `ios/DreamLog/JournalModels.swift`, `LocalStore.swift`, `APIClient.swift` | JSON values, durable local drafts and authenticated HTTPS requests |
| `backend/tests/test_journal.py`, `ios/DreamLogTests/JournalTests.swift`, `HTTPSIntegrationTests.swift` | Backend, draft/recovery and real HTTPS lifecycle verification |

## API and invariants

All routes require the existing device-only Keychain identity as `Authorization: Bearer <user_id>` and remain blocked until the privacy notice is acknowledged.

| Route | Result |
| --- | --- |
| `GET /v1/dreams` | Dated list, default 50 entries, `limit`/`offset` pagination |
| `POST /v1/dreams/search` | Literal title/text search; backend also accepts mood/date/tag filters |
| `GET /v1/dreams/{id}` | Full entry owned by this user |
| `PUT /v1/dreams/{id}` | Create or update with `base_revision`, text, date and metadata |
| `DELETE /v1/dreams/{id}` | Delete the owned entry and cascading records |

The app chooses an entry UUID before saving. Repeating an unchanged save returns the existing entry without creating another row. Text changes increment the revision; stale text edits return 409 and preserve local input. Metadata changes retain the text revision. Entry IDs belonging to another user cannot be read, overwritten or deleted.

Typing persists a draft in the phone's SQLite store; it sends no journal request. Leaving/backgrounding the editor commits changed content by default. Reads never silently submit drafts. Before a save the app records that its result may be unconfirmed. If the response is lost, the next open/commit reads the server first and reconciles the result. Conflict actions let the user reload, keep both texts, use their text or revert their changes. A draft whose stored entry disappeared can be saved under a new ID.

Deletion failure retains local text. Confirmed deletion removes the local draft; an already-deleted server entry is safe to clean up locally. Whole-journal deletion invalidates pending editor work so it cannot recreate the erased local store.

## Next work and deployment differences

Voice recording/transcription, organization, analysis and generated media remain later wiki increments. No AI tasks are scheduled by this milestone. A subsequent foundation request adds Notes CRUD and Profile fields; see [Architecture.md](Architecture.md). Search here is literal text search; semantic search belongs to Increment 8.

The server and mobile contracts are the same locally and on Ubuntu. Changing the HTTPS origin/TLS/storage paths requires configuration, not separate journal code. A managed database engine, App Store signing and release policy work are recorded in [ProductionTransition.md](ProductionTransition.md). No database schema migration was needed: this milestone uses Foundation's existing dreams and drafts tables.
