# Privacy foundation acceptance

The privacy notice and Settings render the same six `privacyParts` constants in `ios/DreamLog/PrivacyNotice.swift`. The concise copy covers AI input boundaries, deletion versus provider retention, server-operator access, permission switches, planned recording deletion, and whole-journal/course-end handling. AI and recording remain unavailable; neither provider retention terms nor a course-end date is invented.

## Confirmation and upgrades

`AppModel.refreshNotice()` requires both the stored version and content fingerprint to match. The fingerprint is SHA-256 over the notice introduction and ordered section titles/text, separated by NUL characters. Editing either the version or any displayed notice text invalidates the acknowledgment. No provider or network call is needed to compute it.

`acknowledgeNotice()` stores both values before allowing normal API calls. A legacy installation with only a version must acknowledge once again. Existing acknowledgment history remains available so the changed notice offers Delete my journal without requiring acceptance. Fresh identity and whole-journal deletion clear both values.

`RootView` gates the tabs and `APIClient` independently gates requests. Only the whole-journal deletion request bypasses acknowledgment. Settings and editor loads remain guarded. Identity remains device-only Keychain data; the content fingerprint is ordinary UserDefaults data and contains no journal identity or user text.

## Remaining external acceptance

The local backend implements Starlette on Granian with HTTPS, SQLite schema initialization, Bearer user resolution and owned GET/PUT/DELETE `/v1/me`. `backend/deploy/dreamlog.service` and `environment.example` provide the Ubuntu configuration. Actual remote deployment still requires the target host, access and TLS certificate; no Ubuntu deployment result is claimed.

The current reminder value is null because reminders are a later increment. Enabling AI or recording requires their implementations and confirmed provider terms. Course-end cleanup remains an operational release requirement; the notice states the project plan, not an already-running deletion schedule. See [ProductionTransition.md](ProductionTransition.md).

Regression results are recorded in [Verification.md](Verification.md).
