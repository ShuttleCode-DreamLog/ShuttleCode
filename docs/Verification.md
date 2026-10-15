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

## Pattern tables for story map Skeletal scope — 13 October 2026

- Backend schema version 4 adds the wiki §4.8.2 pattern tables and the `current_occurrences` view, because story map v2 places pattern discovery in Skeletal. `dream_vectors`, routes, task handlers and the sqlite-vector extension are not added.
- Backend: **63 passed** on Python 3.14.7. The base-schema test now writes one row to each pattern table, reads the corrected tag text and output revision through `current_occurrences`, checks that the dream's patterns switch hides it, checks the correction kind and pair-order constraints, and confirms whole-user deletion empties every pattern table. The additive upgrade test now also covers version 3.
- A real version 3 local database was upgraded by the ordinary `scripts/run-local.sh` start: user_version 4, all new tables and indexes present, `PRAGMA foreign_key_check` empty. The HTTP/2 smoke test passed against it. No iOS change; the app was not rebuilt for this change.

## Course server deployment — 13 October 2026

- Google Cloud e2-micro in us-central1-a, Ubuntu 26.04.1 LTS, external IP 34.66.84.214. The team reports the IP as reserved; this was not checked independently, because the local gcloud account has no access to the project. Deployed commit `e58f3f0` of the `database` branch with uv 0.13.0 and Python 3.14.4. Backend tests on the server: **63 passed**.
- The systemd unit is enabled and active. Granian listens on 443 with a certificate made from the course `selfsigned.cnf`: SAN IP 34.66.84.214, serverAuth, CA:TRUE, valid until 21 January 2027.
- From the Mac over the internet, with certificate validation: 401 without a credential, 200 for GET `/v1/me`, 204 for DELETE. The HTTP/2 smoke test, pointed at the server and its certificate, passed and deleted its temporary user.
- Restart checks: after `systemctl kill -s KILL`, systemd restarted the service (NRestarts=1). After a full VM reboot the service was listening 21 seconds after boot, at the same external IP.
- Server database after these checks: user_version 4, WAL, 20 tables, empty `PRAGMA foreign_key_check`.
- App: `DREAMLOG_SERVER_URL` now defaults to `https://34.66.84.214`. With the server certificate trusted on the iPhone 18 Pro / iOS 27.0 simulator (Xcode 27.0), DreamLogHTTPS: **31 tests passed, 0 failed**. They include the real lifecycle test against the deployed server (Journal, Notes with a photo, Profile, whole-journal deletion); the server's request log shows its requests. DreamLogUI was not run against the server, and no physical phone was checked.
- Not done: `apt upgrade`, a real `GEMINI_API_KEY` (a placeholder until the first AI increment), sqlite-vector.

## dream_vectors and Skeletal contracts — 13 October 2026

- Schema version 5 adds `dream_vectors` (wiki §4.8.2). `index_dream`, the first pattern task, writes it together with `occurrences`, so Skeletal pattern discovery needs it. Backend: **64 passed**. The base-schema test writes a `dream_vectors` row and checks its deletion with the user; the additive upgrade test covers versions 1–4.
- The version 4 local database upgraded to version 5 through `scripts/run-local.sh`: the table and its index are present, `PRAGMA foreign_key_check` is empty, and the HTTP/2 smoke test passed. The deployed server stays at version 4 until its next deploy.
- [SkeletalContracts.md](SkeletalContracts.md) records the routes and fields that the remaining Skeletal cards need, condensed from the wiki's Section 4. No route was implemented.

## Server redeploy at schema version 5 — 13 October 2026

- After pull request #2 was merged, the server checkout moved from `database` to `foundation` at `b50121e`. A `.backup` copy of the version 4 database was taken first and removed once the upgrade worked.
- The restart upgraded the database to version 5: `dream_vectors` and its index are present, the existing user was kept, and `PRAGMA foreign_key_check` is empty. From the Mac: 401 without a credential, and the HTTP/2 smoke test passed against the server.

## Dream permissions route — 13 October 2026

- `PUT /v1/dreams/{id}/permissions` changes only the switches sent, in one transaction with the ownership read, without raising the text revision. Backend: **92 passed**, 28 of them in `tests/test_permissions.py`: partial changes, all six off and back one at a time, repeats and `{}` without a write, creation permissions, a text save after a change with no reload, 404 for another user or a missing dream, 401 for missing or malformed identity, 400 for nine malformed bodies, wrong content type, malformed IDs, 413 for an oversized body, ignored unknown fields, 405 for other methods with the dream kept, concurrent changes to different switches, a seeded 300-step random sequence checked against a reference model, and list/search/delete/user deletion afterwards.
- Mutation check: six deliberately injected bugs (no ownership check, omitted switches reset, revision raised, a write when nothing changed, only the first switch applied, null accepted) each made the new tests fail; the original code was restored.
- Local Granian HTTPS: the HTTP/2 smoke test, now including a permissions change and read-back, passed; a curl walkthrough gave 201, 200 with revision 1, 400 for null, 404 for another user. Not deployed: the server deploys `foundation` after the pull request is merged. No iOS change.

## Gemini API key on the server — 13 October 2026

- The real `GEMINI_API_KEY` replaced the placeholder in `/home/ubuntu/.env.sys` (mode 600, owner `ubuntu`); it was passed over SSH standard input, not as a command argument. The service restarted cleanly. A `models.list` request to `generativelanguage.googleapis.com` with the key answered 200 and listed 63 models. No provider call is made by DreamLog code yet, and the key's plan terms (wiki 4.1 deployment checks) are not confirmed.

## Task worker and AI task interface — 15 October 2026

- `tasks.py` implements wiki 4.3.3: idempotent scheduling by `request_key`, a worker loop started in the lifespan (`START_WORKER`), claims in `run_after`/insertion order for registered types only, outcomes `Done`/`Obsolete`/`Failed`/`RunAgain`, three attempts with 15/60 s or 60/300 s delays, release of rows left running, the start-up restart rule, `dream.tasks`, journal `status` and `POST /v1/tasks/{id}/retry`. `records.py` adds `charge` and `is_cap_reached` with the server-wide ceiling (4.3.8); `providers.py` holds `ProviderError`. No task type has a handler yet, so production schedules nothing.
- Backend: **109 passed**, 17 of them in `tests/test_tasks.py`, which cover wiki 4.3.12 items 3–8, 16, 18 (charge after deletion), 21 and 25 with stand-in handlers and a controlled clock, plus the task fields of the dream object, journal and search status, and the fault route's task form. Three failures on the first run were test mistakes (an async generator used with `next()`, a ceiling counted one too high, a search word removed by the test's own edit), not implementation faults.
- Mutation check: 21 injected bugs in `tasks.py` and `records.py`; the first run caught 20, the missed one (generation tasks in `dream.tasks`) exposed a test that did not isolate the rule, and the strengthened test then caught it. The original code was restored and the full suite passes.
- Local Granian HTTPS: a task planted as `running` with one attempt was `waiting` after start-up; the HTTP/2 smoke test passed; the retry route answered 200 twice, 404 for another user, 401 without a credential and 409 for a completed task; SIGTERM shut the worker down without an error report. Not deployed; no iOS change.

## organize: summary and tags — 15 October 2026

- `organize` (wiki 4.5.7) is the first task handler: `dreams.py` checks the dream (same revision, text, `analysis` switch), charges one `text` unit, sends only the wrapped dream text with `organize-1` through the Gemini text adapter in `providers.py`, validates the answer (summary required and cut at a word boundary to 600 characters; unknown categories, empty or over-long labels, duplicates and excerpts not found in the text are dropped; excerpts stored as written in the text; at most 30 tags) and saves output and tags in one transaction after rechecking the dream. `records.py` adds `save_output`, `source_changed`, `dream_text_changed` and `schedule_processing`; saving a new text revision or turning a switch on schedules `organize`. `dream.organization` and journal `summary` are filled, and the tag filter now finds organized dreams.
- Backend: **144 passed**, 35 of them in `tests/test_organize.py` with a stand-in for the adapter and a mock HTTP transport for the adapter itself (request shape; 400-with-key, 401, 402, 403, 404 → `provider_config`; 422, other 400 → `provider_rejected`; 429; 500/503; `content_filter`; `length`; malformed bodies; connection failure; timeout). Three existing test files were adjusted for the new behavior: `test_journal.py` now expects the scheduled `organize` task, the generic task tests create dreams with analysis off, and the fixture sets `TEXT_MODEL`.
- Mutation check: 32 injected bugs; 30 caught at first, the two misses (display of a removed tag, metadata edits scheduling work) each led to a new test, after which both were caught.
- Trial calls from this Mac and a real local Granian run: saving an invented dream queued `organize`, the worker called Gemini at once, the 402 answer became `provider_config` with a 60-second retry, the log held `status=402 model=gemini-3.8-flash` and neither the key nor the dream text, and the HTTP/2 smoke test passed. A successful real summary awaits a topped-up prepaid balance. Not deployed: the server needs `TEXT_MODEL` in `.env.sys` first. No iOS change.

## organize against the real Gemini API — 15 October 2026

- With a free-tier key (AI Studio project without billing) on the Mac and the server, `gemini-3.1-flash-lite` became the default `TEXT_MODEL`; the other free-tier results are in [ProductionTransition.md](ProductionTransition.md). Running the real `organize-1` instruction, schema and checks on two invented dreams kept 7 of 7 items each, in English and in Chinese; the Chinese account got a Chinese summary and labels.
- Real local Granian run: saving an invented dream queued `organize`, which completed on its first attempt about 5 seconds later (246 prompt and 329 completion tokens). `dream.organization` held a current summary and 7 tags with excerpts found in the text, the journal item showed the summary with status `ready`, the tag filter found the dream with an upper-case tag, `usage` counted one `text` unit, and the log held neither the key nor the dream text. Not deployed.

## analyze: analysis with sources and life notes — 15 October 2026

- `analysis.py` implements wiki 4.6.3–4.6.5 without the MVP meaning-based candidates: terms from current tags (word fallback with `CONTEXT_STOP_WORDS`), up to 4 life notes by terms and date windows (ongoing first), up to 3 earlier dreams with at least two matching terms, `DESC`, the history switch, the `analyze` handler with label checks, one repair call and withholding, the pre-save check of everything sent (`context_changed`), and the two analysis routes. `records.py` adds `source_removed` and rule 3 of `schedule_processing`; the dream save marks the analysis on a mood or date change, and notes and dreams call `source_changed`/`source_removed` on edit, exclusion and deletion.
- Backend: **156 passed**, 12 of them in `tests/test_analysis.py`, covering wiki 4.3.12 items 10–12. A first run found one real bug: the checks for "a memory label" and "an earlier-dream label" used `startswith('M')`/`startswith('D')`, and `DREAM` and `DESC` begin with D, so `related_dreams` was always possible and a section citing only `DESC` passed as citing an earlier dream; both now require the letter followed by digits. Another first-run failure was a wrong test expectation (a note recorded before its future event date counts from its recording day, as the wiki says).
- Mutation check: 41 injected bugs; 38 caught at first, the three misses (an excluded note and a one-match dream hidden by the context limits, and analysis after a capped organize) each led to a stronger test, after which all were caught.
- Real local run with the free-tier key: a note, an earlier dream and a new dream; `organize` and `analyze` each met one 503 and completed on retry. The analysis had six sections, cited `M1` for the waking-life connection, withheld none, and listed `DREAM`, `DESC`, `M1` as context; the earlier dream did not reach two literal term matches, as base retrieval allows. The log held neither the key nor any dream or note text. Not deployed.

## Pattern discovery: indexing, matching, findings and corrections — 15 October 2026

- `patterns.py` implements wiki 4.8.1 steps 1, 2 and 4–7 (search and meaning-based analysis context are MVP and not built): sqlite-vector loading with a fallback flag, `providers.embed`, the `index_dream`, `match_patterns` and `refresh_findings` handlers, candidate selection with the correction constraints enforced before and after the call, evidence keys, `GET /v1/patterns` and the label, dismiss and split routes, the start-up back-fill, and the Arc C hooks in `dream_text_changed`, the permissions route and dream deletion. `schedule_processing` gains rule 4.
- Deployment checks on this Mac: sqlite-vector 1.1.2 loads; `vector_full_scan` with three arguments returns every row, so the per-user condition is a plain `WHERE`; a stored vector read back as little-endian floats and bound as JSON text is at distance 0 from itself. Embeddings: see [ProductionTransition.md](ProductionTransition.md).
- Backend: **183 passed**, 27 of them in `tests/test_patterns.py` with a keyword-based embedding stand-in over the real extension and a stand-in matcher that reads the sent content. They cover wiki 4.8.11 items 1–4, 6, 8–34 in their Skeletal parts, 49–53, 55–57 and the embedding adapter.
- Mutation check: 41 injected bugs; 27 caught at first. The misses showed scenarios where two constraints blocked at once, a waiting refresh hid a repeat, cleared texts hid an explanation, and two test-helper bugs (a final-only assertion, and an edit helper that sent a stale `base_revision` so the second edit never happened). After the fixes 40 are caught; the remaining one, the user condition in the vector query, is equivalent because the candidate pool is already per user.
- Real local run with the free-tier key: four invented dreams first gave zero findings, because `match-1` did not say clearly that a `new_group` targets a `U` label; the model put the target into a second decision, which the checks rightly dropped. After clarifying the instruction, five invented dreams (train, bus and ferry missed; exam room; happy station) gave two recurring findings of the three transport dreams in about 95 seconds, with the station and exam-room dreams left out. Quality to tune at the real-service checks (wiki 4.8.11 items 38–42): the second finding groups by the common noun "public transport", weak members such as "pier" joined, and flash-lite still writes "O1"/"U1" into some `difference` texts although `match-1` now forbids it. The log held neither the key nor any dream text. Not deployed.

## Summary and tag corrections — 15 October 2026

- `PUT /v1/dreams/{id}/corrections` follows wiki 4.5.3: normalized tag text, a repeat changes nothing, a rename to another tag's present text becomes a removal, the original text takes a correction back, and a change raises the organization's revision, calls `source_changed`, and for a tag deletes its pattern membership, empties its group's texts, schedules a refresh and calls `schedule_processing`. The story map has no card for it; the user asked for it.
- Backend: **188 passed**, 5 of them in `tests/test_corrections.py` (validation, the summary cycle, rename/remove/restore/duplicate, outdated analysis, pattern reset and re-indexing). Mutation check: 17 injected bugs, 16 caught; the unknown-category check is equivalent at the HTTP level, because a category without tags already fails the tag lookup with 400.
- Real local run: after real `organize` and `analyze`, a summary correction, a tag rename, removal and restore answered 200 with the expected organization, an unknown tag 400, and the analysis became `outdated`. No key or dream text in the log. Not deployed.
