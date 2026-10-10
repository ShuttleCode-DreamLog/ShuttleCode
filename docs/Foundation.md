# Foundation implementation plan

## Scope and authority

The original assignment was Increment 0 (Foundation), as specified by the workspace `AGENTS.md` acceptance criteria and `ShuttleCode.wiki/Project-Architecture-and-Features.md` §4.1. Foundation is implemented; the user's subsequent text-journal request adds Increment 1, documented in [TextJournal.md](TextJournal.md). The wiki is the top-level design; the repository's `CLAUDE.md` defines coding rules. Implement a proof of concept with flat modules, direct SQL, native SwiftUI/Observation and structured concurrency.

Granian is required explicitly by the workspace `AGENTS.md` server-start acceptance criterion. The wiki §2 and §4.3.1 select Starlette on Granian, SQLite, HTTPS and one application worker. The wiki attributes this selection to course tutorials; that attribution has not yet been independently verified against the original tutorials. Granian runs the Python ASGI application and handles HTTP/TLS; Starlette implements routes. This is an existing project decision, not a new recommendation by the implementation agent.

The code repository is `ShuttleCode/`, separate from `ShuttleCode.wiki/`. At implementation start it contains README and CLAUDE.md, but no application. A pre-existing deletion of repository AGENTS.md is preserved; the applicable instructions are retained in CLAUDE.md and the workspace AGENTS.md.

## Roadmap and implementation locations

1. Establish `backend/` and `ios/`, API types, error format and the full Arc A base schema. Tables arrive in Foundation; business routes and task handlers arrive only in their assigned increments.
2. Implement `backend/config.py`, `db.py`, `web.py`, `records.py`, `main.py` and `dreamlogd.py`: startup, transaction safety, Bearer UUID resolution, GET/PUT/DELETE `/v1/me`, ownership and cascading deletion. Test routes before connecting the phone.
3. Implement `ios/DreamLog/{DreamLogApp,RootView,AppModel,Identity,APIClient,LocalStore,Models,PrivacyNotice}.swift`: device-only identity, local storage, shared state, mandatory versioned notice and request gating.
4. Implement `Settings.swift`: six shared privacy parts, server-authoritative history switch and timezone/reminder/history updates. Automatic alignment sends at most one PUT per launch and preserves the history value returned by GET.
5. Finish deletion recovery: cancel and await the common URLSession, persist deletion state, delete server records, erase local database/recordings/cache/defaults, remove Keychain identity last, then return to the notice with a new identity. Failed deletion supports retry, phone-only erasure with confirmation, and cancel.
6. Supply `backend/deploy/` systemd/environment examples and deployment instructions. Run pytest, Swift Testing and a local Granian HTTPS smoke check; report physical-device and remote deployment checks separately.

Tests live in `backend/tests/` and `ios/DreamLogTests/`. Samples live in `samples/`. Remote deployment follows the wiki path `/home/ubuntu/dreamlog/backend` on Ubuntu, managed by systemd.

## Invariants and edge cases

- No API call before acknowledgment, except explicitly permitted deletion/recovery actions. Acknowledgment requires the version and content fingerprint to match, so text changes also require renewed acknowledgment without a version bump. Settings reads exactly the same six constants. See [PrivacyAcceptance.md](PrivacyAcceptance.md).
- The lowercase UUID exists only in device-only, nonsynchronized Keychain; it is neither displayed nor logged. A read failure is an error, never permission to generate a fallback identity.
- Bearer identity is the only owner authority. Missing/malformed/uppercase UUIDs receive 401. Body owner fields never authorize a request.
- Settings controls wait for GET `/v1/me`; every phone update sends timezone, nullable reminder weekday and history together. UI adopts the response.
- Delete is unavailable while recording or streaming. A canceled request must not update app state after deletion starts. Cleanup interruptions resume before ordinary loading. Keychain removal is last.
- SQLite foreign keys cascade all base records; usage counters are explicitly deleted for that user while server-wide counters remain. Files are removed after commit and orphaned audio is swept on startup.
- Before Increment 7, reminders are null. Journal implements text capture; Notes now implements direct memory CRUD and Settings has extensible Profile fields, following the user's subsequent foundation request. None schedule AI tasks. See [Architecture.md](Architecture.md).

## Facts still needed

The user selected local-first development: another Mac must be able to clone and run the app/backend. Cloud deployment is a later milestone; the team will provide the Ubuntu host/SSH access, static IP and cloud selection then. No remote deployment is claimed. Configuration and future database/App Store differences are recorded separately in docs/ProductionTransition.md. Provider plan/retention terms and project-end date remain unconfirmed: use the wiki's provisional notice wording, then bump noticeVersion when those facts are supplied. Confirm course tutorial contracts before remote deployment. Test only invented journal data until the later privacy/permission and provider checks are complete.

## Later increments

1 text capture (implemented) → 2 voice capture → 3 organization → 4 analysis → 5 profile memory AI context → 6 discussion → 7 weekly check-in → 8 patterns/search → 9 images → 10 video. The present implementation includes Foundation, text capture and the subsequently requested Notes/Profile CRUD. Notes storage was brought forward; its AI context behavior remains later work.
