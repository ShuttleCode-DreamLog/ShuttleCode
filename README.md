# DreamLog

Voice-first dream journal with embedded AI (EECS 498-002 F26 MDE).

Journal and Notes support creation, reading, editing and deletion. Journal saves edits by default and offers Revert, with local drafts and text search. Notes supports photo attachments; Settings includes editable profile fields such as name and age. The backend is Starlette/Granian HTTPS with SQLite. Device identity, a short privacy notice and whole-journal deletion are shared foundations. Voice capture and AI features follow later.

- [Run locally on a Mac](docs/LocalDevelopment.md)
- [中文新手指南：Swift、数据库与增量开发](docs/BeginnerGuide.zh-CN.md)
- [Architecture and collaborator file map](docs/Architecture.md)
- [Callable JSON API contracts](docs/API.md)
- [Automatic journal save, note photos and AI integration points](docs/EditorAndPhotos.md)
- [Privacy acknowledgment and acceptance](docs/PrivacyAcceptance.md)
- [Text journal usage and implementation](docs/TextJournal.md)
- [Task scope, decisions and roadmap](docs/Foundation.md)
- [Cloud/database/App Store transition](docs/ProductionTransition.md)
- [Verification record](docs/Verification.md)
- [Coding instructions](CLAUDE.md)

The app connects to the deployed course server `https://34.66.84.214` by default: trust that server's certificate on the simulator, then run `ios/DreamLog.xcodeproj`. For a backend on your Mac, start `./scripts/run-local.sh`, trust its certificate and override `DREAMLOG_SERVER_URL`. See the local guide for exact commands.
