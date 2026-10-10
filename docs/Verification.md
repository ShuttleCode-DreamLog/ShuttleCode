# Foundation verification — 8 October 2026

## Completed on this Mac

- Backend: Python 3.14.8, Granian 2.8.4, Starlette 1.7.0. `uv.lock` pins the dependency set; `uv sync --locked` succeeded through the local launcher.
- `backend/.venv/bin/python -m pytest -q`: **20 passed**. Coverage includes invalid/missing/uppercase Bearer identity, write-free reads of known users, two-user settings isolation, nullable reminders, ignored unknown timezone, strict input types/body limit, error/request-ID format, all base tables populated and deleted together, representative schema checks, effective tags, foreign keys, file ownership, preserved server-wide usage, repeated deletion, canceled transactions, schema mismatch and sanitized fault logs.
- Xcode 27 / Swift 6, iPhone 17 Pro simulator on iOS 26.5: **13 passed, 0 failed, 0 skipped** with the DreamLogHTTPS scheme. Twelve isolated tests cover privacy gating, explicit reminder null, Bearer headers, at-most-one automatic settings PUT with preserved history, old notice reappearance, fresh-identity reset of restored defaults, deletion success/failure/cancel/recovery, server-authoritative history, busy deletion prevention, six shared privacy parts, in-flight cancellation and incompatible local schema refusal.
- The thirteenth test uses the actual signed iOS app's AppModel/APIClient and the local Granian HTTPS server: first-launch gate → acknowledgment → GET and timezone alignment → history update → DELETE → new identity and first-launch notice. It uses the simulator's native certificate trust, with no TLS bypass.
- `backend/tests/smoke_https.py`: real HTTPS certificate validation, HTTP/2, 401 without credentials, successful GET/PUT/DELETE.
- Real Granian fault check at LOG_LEVEL=DEBUG: a deliberately content-bearing exception produces the safe 500 format. The captured process log contains its type, file/line and request ID; it contains neither the marker text nor the local placeholder key. The fault route is disabled for ordinary local startup.
- The ordinary simulator app was launched and its first-launch notice visually checked. The ordinary server log showed no API request while that notice remained unacknowledged.
- The built app plist contains the configured DreamLogServerURL. Shared schemes and synchronized source folders are checked in. Local startup script syntax and Git whitespace checks pass.

Simulator Keychain tests initially failed with signing disabled (`-34018`). Keeping local simulator signing enabled resolves that; no fake identity or mock Keychain was added.

## How to repeat

Follow `docs/LocalDevelopment.md`. The normal DreamLog scheme runs isolated tests and skips the network test. To include it, start `scripts/run-local.sh`, boot the selected simulator, trust `backend/.local/server.crt`, then run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/DreamLog.xcodeproj -scheme DreamLogHTTPS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO
```

Disabling parallel simulator clones ensures the network test uses the simulator where the certificate was trusted.

## Not claimed

- No remote Ubuntu/cloud deployment, managed database migration or App Store submission has been performed. The user selected local-first; deployment artifacts and transition notes are provided.
- No physical-phone verification or second developer's clone has been run. The documented clone workflow and native simulator/backend lifecycle were verified on this Mac.
- Provider plan/retention terms, quotas, actual AI calls, notice wording approval and course-end date remain team checks. This increment has no AI adapters or processing.
- At the original Foundation check Journal/Notes were placeholders. Subsequent verification below supersedes both limitations. Recording, reminders, AI context, discussion and generated media remain later increments. Privacy copy is now brief and provisional at the user's request.
- SQLite remains the backend database. A managed database engine or cross-device/account-recovery feature requires the separate design changes recorded in `docs/ProductionTransition.md`.

## Text journal verification — 8 October 2026

- Backend: **35 passed**, including 15 new journal cases for create/read/repeated save/edit/delete, ownership and ID collisions, revision conflicts, metadata/null handling, limits, dates, source/permission stability, deterministic pagination and literal search escaping.
- Signed iPhone 17 Pro / iOS 26.5 simulator: **21 passed, 0 failed, 0 skipped** with DreamLogHTTPS. Eight added isolated tests cover durable draft reopening/upsert, draft/server row merging, null metadata encoding, Unicode scalar limits, uncertain-save recovery without duplicate PUT, read-without-auto-save, conflict preservation and deletion failure/retry.
- The real HTTPS app lifecycle test now creates a text entry, verifies its list/detail, edits it to revision 2, deletes it, confirms it disappears, then deletes the whole journal and checks the first-launch notice reset. Native simulator certificate trust and the ordinary Granian server are used throughout.
- The HTTP/2 smoke test also creates, reads, lists and deletes a text entry. All test journal content is invented.
- No automated UI tapping or physical-device check is claimed for the new editor. UI interaction checks for + → typing → Save → open → Edit → Delete remain team checks; the connected models, local store and actual HTTPS API lifecycle passed.

## Notes, Profile and collaborator foundation — 8 October 2026

- Backend: **57 passed**. New coverage includes Notes create/read/repeat/edit/delete, optional event dates, ongoing filters, ownership collisions, permission changes surviving content conflicts, malformed bodies/limits, Profile replacement/removal/clearing, custom fields, age validation, user isolation and preservation across device-settings updates.
- Upgrade: version 1 SQLite records survive the additive version 2 profiles-table upgrade; foreign keys remain valid. Other unsupported versions still refuse startup. The phone draft schema remains unchanged.
- Signed iPhone 17 Pro / iOS 26.5 simulator: **25 passed, 0 failed, 0 skipped**, including four new tests for explicit null note dates, retained input and conflict recovery, deletion failure, Profile failure recovery and literal custom field keys.
- The real HTTPS AppModel/APIClient lifecycle now exercises Notes create/list/detail/edit/delete, Profile save/reload/remove-field and whole-user reset, in addition to Journal. The HTTP/2 smoke independently exercises Journal, Notes and Profile read/write/deletion/clearing with native certificate validation.
- SwiftUI screens compile; no automated UI tapping or physical-phone verification is claimed. The shortened notice retains the six shared parts and increments noticeVersion to 2. This build performs no AI calls.
- [Architecture.md](Architecture.md) supplies the collaborator file map and extension points; [API.md](API.md) supplies route contracts, JSON examples, ownership and revision rules. [CLAUDE.md](../CLAUDE.md) records the user's updated minimum-implementation scope.

## Default journal commits and note photos — 9 October 2026

- Backend: **62 passed**. Added real PNG fixtures cover upload/repeated upload, byte reads, metadata in note list/detail, photo removal, foreign-user and cross-note ID refusal, count/size/type/framing validation, note/user cascading deletion, photo-only notes and additive version 1/2 upgrades to version 3.
- DreamLogHTTPS: **27 passed, 0 failed, 0 skipped** on the signed iPhone 17 Pro / iOS 26.5 simulator. Added tests cover default journal commit on close, Revert without another write, and a photo-only note's failed upload retaining its ID/data for retry. The recovery fixture now uses the current date instead of a date frozen to 8 October.
- Actual HTTPS app lifecycle: creates a photo-only note, uploads a generated JPEG, reopens its bytes, removes it, edits/deletes the note, and retains the existing settings/profile/journal lifecycle checks. No provider calls or certificate bypass.
- DreamLogUI: **1 interaction test completed successfully** against the ordinary local backend. It acknowledges the notice through the real scrollable screen, creates the first Notes entry with its new UUID, saves/reopens/deletes it, then creates a Journal through default Done commit, edits and Reverts its text, and deletes that test entry. No existing user records are erased.
- The independent HTTP/2 smoke passes Journal/Notes/Profile/photo upload/read/delete using invented records and an encoded PNG fixture. Git whitespace checks pass in both the code and wiki repositories.
- Photo-library selection on a physical phone is not claimed; the native picker screen compiles and the resulting photo upload/reopen/delete path is verified through APIClient/models. Voice and actual AI processing remain absent. Existing real-service, release and privacy wording checks remain separate.
- Design changes are in [EditorAndPhotos.md](EditorAndPhotos.md), [API.md](API.md), [CLAUDE.md](../CLAUDE.md), and the wiki's Section 2 plus the Detailed Implementation amendment. `AI integration point` comments identify where future processing work belongs.

## Notes Save and Done recovery — 9 October 2026

- Investigation found no process listening on local port 8443 while the user was running the iOS 27 simulator. The local HTTPS backend was restarted and its certificate trusted on that simulator without relaunching the user's app or discarding its input. The earlier haptic console message does not diagnose the failed network save.
- Save now returns success/failure, reports blocked editor states, and permits a new editor to save before its initial load task. Failed saves display an alert and retain text/photos. Done offers Save and close, Discard, and Keep editing; it closes after successful saving only.
- DreamLogHTTPS: **29 passed, 0 failed, 0 skipped** on the separate iPhone 17 Pro / iOS 26.5 simulator. New cases verify saving before initial load and refusing an unacknowledged journal with feedback, retained input and no API request. Existing failure/conflict/photo-retry and actual HTTPS lifecycle cases also pass. Result: `/private/tmp/dreamlog-note-fix-unit.xcresult`.
- DreamLogUI: **1 passed**. The real-screen test saves/reopens/deletes the first note, creates a second note using Done → Save and close, verifies it appears in the list and can be reopened/deleted, and retains the Journal automatic-save/Revert checks. Result: `/private/tmp/dreamlog-note-fix-ui.xcresult`. This test uses a separate simulator and does not relaunch the user's current editor.
- The save-failure alert itself is not covered by automated UI interaction; failed request retention is covered at the model level. No physical-phone verification is claimed. The user must keep the backend terminal running and rerun the app from Xcode to load the new UI after saving current input.

## Privacy content acknowledgment — 9 October 2026

- Notice version 3 supplies six concise shared sections covering the required topics, with unavailable AI/recording explicitly labeled and release/provider/course-end details recorded as external milestones.
- Confirmation now requires both version and the SHA-256 fingerprint of the notice introduction and section titles/text. A changed or missing fingerprint blocks normal API calls even with a matching version. Prior acknowledgment still enables whole-journal deletion without accepting changed terms; deletion and fresh identity clear the fingerprint.
- DreamLogHTTPS: **31 tests passed, 32 parameterized executions, 0 failed, 0 skipped** on the signed iPhone 17 Pro / iOS 26.5 simulator. New coverage includes matching-version changed text, legacy missing fingerprints, zero requests before renewed acknowledgment, deletion from the changed notice, stored confirmation surviving relaunch, and fingerprint cleanup. The version-change test uses a matching content fingerprint so the version check is verified independently. Existing real HTTPS Journal/Notes/Profile/photo/deletion tests pass. Final result: `/private/tmp/dreamlog-privacy-final-tests.xcresult`.
- DreamLogUI: **1 passed** against the local HTTPS backend, including acknowledging the updated privacy screen and the existing Notes Save/Save and close and Journal default-save/Revert flows. Result: `/private/tmp/dreamlog-privacy-content-ui.xcresult`.
- Git whitespace checks pass for the code and wiki. No remote Ubuntu deployment, AI/recording implementation, scheduled course-end cleanup or physical-device test is claimed. [PrivacyAcceptance.md](PrivacyAcceptance.md) records the implementation and remaining external acceptance.
