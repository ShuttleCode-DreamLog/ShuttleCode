### Execution & Scope
* **Craftsman's Creed**: Write flat, functional, concise, idiomatic, ultra-performant code, in absolute terms, without enterprise abstractions, dependency injection, or wrappers (DTO, ORM). Static peer-review before output.
* **System 2 Planning:** Map invariants, edge cases, and dependencies. State assumptions explicitly. Look beyond the direct question at the broader intent. If a simpler, cleaner, more holistic, and more performant alternatives exists, present it and briefly explain the structural "why." Peer-review statically before coding. Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify. 
* **High-Density Output:** Deliver concise, actionable edits. Eliminate all conversational filler or pleasantries. Silently fix syntax and typos. Omit cosmetic diff clutter. Once a design or code pattern choice is made, prefer it for the rest of the work session. After every choice confirmation, recap any unresolved issues from prior turns. 
* **Strict Scoping:** Limit analysis to assigned task files. Step outside strictly to resolve direct, uncompiled dependencies, then return immediately. No abstractions for single-use code. Every changed line should trace directly to the user's request. Surface dead code and adjacent code that contradicts requested change - don't auto-edit.

### Environment & Tooling
* **Target:** Back end bare-metal Ubuntu deployment, local dev may be on a different platform not set up for deployment. NEVER suggest Docker or other containers.
* **Cutting-Edge Platforms:** Target latest toolchains (Swift 6.2+, Kotlin 2.4+, iOS 26+, Android API Level 34+, Go 1.26+, Python 3.12+, Rust 1.97+, TypeScript 7+).

### Universal Language Compliance
* **Expressions Over Statements:** Prefer direct assignment (`switch`, `when`, ternaries, comprehensions, Kotlin scope functions) over multi-line `if-else`. Prefer Kotlin and Swift Result type to handle exception over `try-catch`.
* **Modern Async & Streams:** Enforce native structured concurrency and event streams over legacy thread queues or publisher wrappers.
* **State & DB Mechanics:** Prefer native immutable/reactive state flows. Enforce atomic upserts (`ON CONFLICT...DO UPDATE`) over destructive `DELETE + INSERT`.
* **Rust Ownership Rule**: Always consume collections directly when it is not used later in the scope. Do not borrow or use lifetime adapters on unneeded temporary collections when you can consume.

### Style & Documentation
* **Semantic Variables:** Name elements by functional, system-level purpose—-never implementation details. Per Swift naming scheme, names should read as nouns, not meaningless tags. Match existing style, even if you'd do it differently.
* **Strategic Comments:** Document exclusively *why* an algorithm exists. Never comment on *what* syntax does. Don't remove existing comments, leave them dangling if matching code removed.


### AI Rules
- follow the latest Compose, Go, Kotlin, Python, Rust, Swift, SwiftUI, and TypeScript language features and their respective latest libraries and SDKs, to prevent the LLM from generating outdated, inefficient, or mixed-language code with legacy patterns. Presence of these legacy patterns in your code will lead to automatic point deductions. You MUST include your most up-to-date AGENTS.md or CLAUDE.md when submitting your work.
- not over-engineered to industry-standard concurrency, scalability, security requirements, nor over-engineered for enterprise-level robustness beyond the level implemented in the tutorials and required by the specs. The focus is on a proof-of-concept deliverable rather than enterprise-grade systems. We will bypass mobile-specific non-functional requirements such as offline state sync, battery consumption, network latency, and complex authorization flows.

### Tasks

Acceptance Criteria:

WHEN: the app launches for the first time on a device with no stored notice acknowledgment
THEN: a privacy notice appears before the journal or any other screen, the user cannot reach the main app until they acknowledge it, and the app sends no API request except actions allowed on the notice screen itself (such as delete journal when re-shown after a notice text change).

WHEN: the notice text or noticeVersion changes after the user previously acknowledged an older version
THEN: the notice appears again until acknowledged, and when a prior acknowledgment exists the notice screen also offers Delete my journal so the user can leave without accepting the new text.

WHEN: the user opens Settings
THEN: the privacy text shows the same six parts as the first-launch notice (what is sent to AI; deletion vs provider retention; who can read the server journal; where permission switches live; recording deletion rules; deleting the whole journal and course-project end), read from the same constants as the notice.

WHEN: the app needs to call the backend
THEN: it creates or loads a random lowercase UUID on first launch, stores it only in Keychain (device-only, not iCloud-synced), sends it on every request as Authorization: Bearer <user_id>, never shows the ID in the UI, and never uses a temporary fallback ID if Keychain read fails.

WHEN: AppModel.load() runs after the notice is acknowledged
THEN: it fetches GET /v1/me, and may send at most one PUT /v1/me per launch to align timezone and reminder fields with the phone while preserving the server-returned history switch until the user changes it in Settings.

WHEN: the user changes the history switch in Settings and me has loaded
THEN: the app sends PUT /v1/me with timezone, reminder weekday, and history together, and the UI reflects the server response; a second phone with a different ID keeps its own settings.

WHEN: the backend receives a request without a valid Bearer user ID
THEN: it responds with refusal (invalid or missing user), and never trusts an owner ID from the request body alone.

WHEN: the deployed server process starts
THEN: it runs under the course stack (Starlette on Granian with HTTPS), opens the SQLite database with the base schema, resolves users via resolve_user, and exposes GET /v1/me, PUT /v1/me, and DELETE /v1/me with ownership enforced on every record.

WHEN: the user confirms Delete my journal while the app is not busy
THEN: the app cancels in-flight requests, calls DELETE /v1/me, then removes local store, cached data, relevant defaults, and the Keychain identity, and returns the user to the first-launch notice with a new ID; the server holds no rows for that user after a successful deletion.

### TODO checkbox

- deploy https backend with sqlite and user resolution
- expose get/put/deletev1/me with bearer user id
- store journal id in keychain and gate api calls behind privacy notice
- build settings with privacy text, history switch, and delete my journal

### Current implementation direction
Read the project wiki for top-level design. Foundation, text journals, Notes CRUD and extensible Profile fields are implemented locally; preserve the same API and business logic for cloud deployment. See docs/Architecture.md, docs/API.md, docs/LocalDevelopment.md and docs/ProductionTransition.md. Record any later deployment/database/release differences explicitly.

The user subsequently requested read/write foundations for every tab, extensible profile fields, collaborator APIs, and brief provisional privacy copy. This supersedes full-length privacy prose for the current development build. Keep the acknowledgment/version gate and six shared short parts. Notes now supplies memory CRUD only, not the full AI Increment 5. Profile uses a string dictionary and its own endpoint. Read docs/Architecture.md and docs/API.md first for the current file map and contracts. Use flat functions, direct SQL and existing observable models; do not add generic service/ORM layers.

### Text journal acceptance criteria

- After notice acknowledgment, users can create a text journal, list/read it, edit it and confirm deletion of an individual entry.
- Unsent text persists in local SQLite drafts. Reading never submits a draft; uncertain saves reconcile with the server before retrying.
- Bearer identity controls every journal route. Another user's entry ID grants no access.
- Atomic saves preserve entry IDs; text revisions prevent stale edits from overwriting stored text. Conflicts and deletion failures preserve local input.
- Text capture schedules no AI tasks. Voice and other later wiki increments remain separate.

### Current editor and photo requirements

The user's latest request supersedes the explicit Journal Save button: persist local drafts while typing, commit by default on leaving/backgrounding, and offer Revert to abandon the current edit. Keep input on save failure/conflict. Present new editors with an identifiable entry value so the first Notes save always has its UUID. Notes retains Save and supports up to five authenticated JPEG/PNG attachments, including photo-only notes. Additive backend schema version 3 preserves old records. Keep explicit AI integration-point comments and provider calls on the backend; no empty processing service or fake endpoint. See docs/EditorAndPhotos.md and the updated wiki §2 and implementation amendment for the design.

Notes save failures must be visible in an alert and preserve input. Done offers Save and close, Discard, and Keep editing; dismiss only after successful saving of text and pending photos. Saving a new note must not depend on its initial view load task having run, and old editors must remain rejected after whole-journal deletion. Xcode does not start the local backend: keep scripts/run-local.sh running and trust its certificate on the selected simulator. See docs/LocalDevelopment.md for recovery without discarding input.

Privacy acknowledgment requires both noticeVersion and the SHA-256 fingerprint of the shared six parts plus notice introduction. Text-only changes and legacy acknowledgments without a fingerprint must re-show the notice with the prior-acknowledgment deletion option. Clear both acknowledgment keys on whole-journal deletion or fresh identity. Keep the six parts concise but cover AI inputs, provider retention versus deletion, server access, switches, recording deletion, and whole-journal/course-end handling. Label future features as planned; do not imply AI/recording or course-end cleanup already runs. See docs/PrivacyAcceptance.md.
