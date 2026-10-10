# Local development to cloud and App Store

The requested first milestone is a cloneable Mac setup. Local and deployed builds use the same Swift app, Python application, REST endpoints, JSON types, identity rules, privacy gate, ownership checks and deletion workflow. Local setup does not introduce a separate mock backend.

## Configuration changes, without business-code changes

| Concern | Local | Cloud / release |
| --- | --- | --- |
| App origin | `DREAMLOG_SERVER_URL=https://127.0.0.1:8443` | Override with the production HTTPS origin at build time |
| Backend process | `scripts/run-local.sh`, port 8443 | `backend/deploy/dreamlog.service`, port 443 on Ubuntu |
| TLS | Developer-generated certificate explicitly trusted by simulator | Publicly trusted certificate for the chosen domain; configure TLS_CERT/TLS_KEY and renewal |
| Storage | Ignored `backend/.local/data` | Persistent private directory on the server via DATA_DIR |
| AI credentials | Unused Foundation placeholder | Real server environment secret and verified model identifiers when their increments arrive |
| Signing | Local simulator signing / personal device team | Team's distribution signing and App Store Connect configuration |

The client always verifies HTTPS certificates. There is no TLS bypass, App Transport Security exemption, direct database connection from iOS, or AI key in the app. Cloud provider calls belong on the backend through the provider adapters planned by the wiki.

## Remote database: distinguish hosting from changing engines

Hosting the existing SQLite database on the Ubuntu cloud machine follows the current design. The iOS app accesses it through the same `/v1` API; no mobile changes are required. SQLite remains a file on that server's persistent local disk.

If “remote database” later means a managed PostgreSQL or other database service, this is a separate architecture change from the wiki's SQLite selection. SQL, connection/transaction code, schema creation/versioning and integration tests will need adaptation. Keep HTTP response contracts stable so the mobile app does not change. Do not put a SQLite file on a remote/network filesystem as a substitute for a managed database. Engine selection and data migration require their own documented decision before implementation; no generic repository/ORM layer is added preemptively.

## Release work still required

Foundation is a course proof of concept, not an App Store release claim. Before release the team must settle provider plan/retention wording, project-end or continuing-service policy, operational access to journals and intended user support. Update the six shared privacy parts and increment noticeVersion for a policy revision. A content fingerprint also forces renewed acknowledgment if the text changes without a version bump; legacy version-only acknowledgments must be renewed. See [PrivacyAcceptance.md](PrivacyAcceptance.md).

The course design associates a journal with a device-only bearer UUID. Cross-device access, account recovery, lost-phone deletion and login are not provided. If the release needs those, document and implement a new identity/account design while retaining ownership enforcement and notice behavior.

Text journal creation, reading, editing and deletion are implemented. Complete the remaining planned features and production endpoint before submission. Prepare a privacy policy URL, App Store privacy disclosures, app metadata/icons, signing, review access and release tests. Confirm current Apple requirements from official guidance at the release milestone; this document is an implementation transition plan, not a guarantee of approval.

Notes CRUD and extensible Profile fields are also implemented using the same local/cloud HTTP routes. Profile is stored as a JSON string dictionary in the additive version 2 profiles table; it requires no new mobile deployment behavior and is not supplied to AI. If switching database engines, migrate that dictionary alongside users, journals and notes. The user's requested short development privacy copy is provisional; restore complete, confirmed terms before activating AI/recording or submitting a release, and bump noticeVersion.

Schema version 3 adds note-photo BLOBs with ownership/cascading deletion. These small bounded attachments share SQLite in the proof of concept. If moving images to remote object storage or another database engine, record and test that migration separately, keeping the existing authenticated photo routes and metadata stable. [EditorAndPhotos.md](EditorAndPhotos.md) records this storage choice and the future provider-API integration points.

Cloud deployment must validate quotas/provider terms before AI use. The current SQLite design requires one application worker. Horizontal scaling or a database engine change needs an explicit plan rather than increasing worker count. Schema edits must preserve real journals once they exist. Backup retention and deletion wording must remain consistent if the team changes the course's no-backup policy.

## Deliberate implementation differences from the current wiki

- The wiki's manually edited `serverAddress` constant is replaced by one Xcode build setting and a minimal Configuration/Info.plist. This meets the requested cloneable local workflow and permits a release origin without changing Swift source.
- The Foundation APIClient is a main-actor final class with an explicit privacy gate and an ephemeral URLSession. The wiki proposed a nonisolated stateless struct. The class keeps the gate and session invalidation owned in one place; it introduces no API protocol or dependency-injection layer. Revisit only when later streaming/download increments need concurrency beyond Foundation.
- The local launcher provides a placeholder GEMINI_API_KEY only for Foundation, which has no provider calls. Production startup retains the required-key contract from the wiki. Never use the placeholder for AI increments.
- The Xcode project was generated as checked-in project metadata rather than created interactively in Xcode. It uses synchronized source folders, a shared scheme, Swift 6 mode, main-actor default isolation, iOS 26 minimum, automatic signing and generated standard Info.plist keys. A minimal input plist is required because Xcode does not emit arbitrary INFOPLIST_KEY_* settings into a generated plist; it carries only the configurable server URL. Microphone usage remains a target build setting.
- LocalStore uses the specified drafts table and now implements draft CRUD alongside whole-store cleanup. Recording operations remain for voice capture. Text capture requires no schema change or separate local backend.

## Ubuntu deployment artifacts

`backend/deploy/dreamlog.service` and `environment.example` follow the wiki's filesystem paths. Supply the environment file privately at `/home/ubuntu/.env.sys` (mode 600), run `uv sync --locked` in the backend directory, install the service unit, enable/start it, and inspect the journal. Provide a persistent DATA_DIR writable only by the service user. TLS material must match the deployed hostname/address.

No cloud deployment has been performed: local-first is the selected milestone. A real server address, access and TLS/domain decisions are needed at the cloud milestone.
