# Skeletal API contracts

This page is the agreement between the backend and the iOS app for the Skeletal cards of story map v2 (revised 11 October 2026). [API.md](API.md) documents what is implemented; this page adds the routes and fields that the remaining Skeletal cards need. The shapes are condensed from the wiki's Section 4, which stays the source of the full behavior; each heading names its subsection.

## Card map

| Story map card | Contract | Status |
| --- | --- | --- |
| Start the server, set up the journal, open settings | `/v1/me`, `/v1/me/profile` | Implemented |
| Type and save, browse, reopen, edit, delete a dream | `/v1/dreams`, `/v1/dreams/{id}` | Implemented |
| Sync queued dreams when the connection returns | Existing `PUT /v1/dreams/{id}`: client-chosen ID, `base_revision`, a repeated save returns the stored dream | Server implemented; the app's automatic resend is missing |
| Filter the journal by date or tag | `POST /v1/dreams/search` with `from_date`, `to_date`, `tag` | Server implemented, including tags from `organize`; the app has text search only |
| Generate an AI summary and tags | `dream.organization`, `dream.tasks`, journal item `summary` and `status`, task retry | Server implemented: `organize` runs on each new text revision and fills `organization` and `summary`; the app's display is missing |
| Automatic dream analysis with its sources | `GET /v1/dreams/{id}/analysis`, `POST /v1/dreams/{id}/analysis/refresh` | Planned |
| Include life notes in a dream's analysis | `memory` entries in `analysis.context` | Planned, with analysis |
| Exclude a dream or note from AI use | Dream: `PUT /v1/dreams/{id}/permissions`. Note: `allow_analysis` in `PUT /v1/memories/{id}` | Server implemented for both; the app's dream switches are missing |
| Recurring patterns with counts and evidence | `GET /v1/patterns` | Planned |
| Rename, dismiss, split a pattern | `PUT /v1/patterns/groups/{id}/label`, `POST …/dismiss`, `POST …/split` | Planned |

## Working agreement

1. The backend ships a route with its tests and a `curl` check first, then moves its row in [API.md](API.md) from this page to "implemented". The app adds its Swift types against that.
2. JSON keys are snake_case and timestamps are Unix milliseconds. The app decodes with `convertFromSnakeCase` and `millisecondsSince1970`, so Swift properties are the camelCase form of the keys below.
3. The app ignores fields it does not know, but a missing or mistyped field fails decoding. The backend therefore adds a field before the app requires it. New Swift enums carry an `unknown` case so a new server value never breaks decoding.
4. There is no push and no polling timer. A screen's `load()` reads its records, including their tasks, when the view opens, when the app returns to the foreground and on pull to refresh (wiki 4.4.6). After a changing request the app uses the record in its response.
5. Every route requires `Authorization: Bearer <user_id>`, and IDs of another user answer 404.

## Errors the Skeletal routes add (wiki 4.2.3)

The backend returns `invalid_request` 400, `invalid_user` 401, `not_found` 404, `revision_conflict` 409, `too_large` 413 and `internal` 500 today. The Skeletal routes add:

| Status | `error` | When |
| --- | --- | --- |
| 403 | `not_permitted` | The record's switch for this AI use is off, for example a refresh of a dream whose `analysis` is off. |
| 409 | `invalid_state` | The record's state does not allow the request, for example a correction while organization is outdated. |
| 429 | `cap_reached` | The user's daily cap on paid generation is used up. |
| 429 | `ceiling_reached` | The server-wide daily ceiling is used up. |

Failed AI work is not an HTTP error: it is reported in the task's `error_code`.

## Task object and retry (wiki 4.3.3)

Implemented on the server; see [API.md](API.md#ai-tasks). The app still needs the target `TaskInfo` below and a retry action.

```json
{"id": "5b0c…", "type": "organize", "status": "failed", "error_code": "cap_reached",
 "dream_id": "9f1e…", "subject_id": null, "source_revision": 2, "updated_at": 1760371200000}
```

| Field | Type | Values |
| --- | --- | --- |
| `type` | string | `transcribe`, `organize`, `analyze`, `index_dream`, `match_patterns`, `refresh_findings`, `generate_image`, `generate_video` |
| `status` | string | `waiting`, `running`, `completed`, `failed`, `canceled`, `obsolete` |
| `error_code` | string or null | Set when `failed`, or `waiting` after a failed attempt |

`POST /v1/tasks/{task_id}/retry`, no body: 200 with `task`. A `waiting` or `running` task is returned unchanged; a `failed` one checks the cap (429) and returns to `waiting`. 409 `invalid_state` for `completed`, `canceled` or `obsolete`. There is no route that lists tasks: each record's read returns the tasks that concern it.

Error codes with their own wording in the app (wiki 4.4.6): `cap_reached` and `ceiling_reached` (name the 00:00 UTC reset in local time), `rate_limited`, `provider_config`, and `provider_refused` (worded per kind of work; a refused organization or analysis is explained on the dream's screen and leaves no mark on the journal row). Any other code: "could not be completed" with retry.

| Swift today | Target (wiki 4.4.3) |
| --- | --- |
| `TaskInfo { id, type: String, status: String }` | `TaskInfo { id, type: TaskType, status: TaskStatus, errorCode: String?, dreamId: String?, subjectId: String?, sourceRevision: Int?, updatedAt: Date }` with the two enums above plus `unknown` |

## Dream object and journal item (wiki 4.5.3)

Implemented on the server; see [API.md](API.md#summary-and-tags). The app still needs the target `Organization` and `Tag` types below.

`dream.tasks`: for the dream's present revision, the newest task of each type, without `generate_image` and `generate_video`; `transcribe` always counts. `dream.organization`: null until an organization output exists.

```json
"organization": {
  "status": "current",
  "dream_revision": 2,
  "summary": "A night walk by a blue lake.",
  "summary_corrected": false,
  "tags": [
    {"category": "place", "text": "blue lake", "original_text": "lake", "excerpt": "by a blue lake",
     "feeling": null, "corrected": true, "removed": false}
  ],
  "created_at": 1760371200000
}
```

| Field | Values |
| --- | --- |
| `status` | `current` or `outdated` |
| `tags[].category` | `person`, `place`, `object`, `action`, `emotion`, `theme` |
| `tags[].feeling` | `stated`, `inferred` or null (emotion tags) |
| `tags[].removed` | A tag the user removed is still returned, with its original text, for the dream's own screen |

Journal item: `summary` is the effective summary of a current organization, otherwise null. `status` is `attention` when the newest `transcribe`, `organize` or `analyze` task of the present revision failed (except `provider_refused` for organization or analysis), otherwise `processing` while one is `waiting` or `running`, otherwise `ready`.

| Swift today | Target (wiki 4.5.8) |
| --- | --- |
| `Organization { status: String, dreamRevision, summary }` | `Organization { status: OutputStatus, dreamRevision: Int, summary: String, summaryCorrected: Bool, tags: [Tag], createdAt: Date }` |
| none | `Tag { category: TagCategory, text, originalText, excerpt: String, feeling: Feeling?, corrected: Bool, removed: Bool }` |
| `JournalItem.status: String` | `status: ServerStatus` (`ready`, `processing`, `attention`, `unknown`) |

## Dream permissions (wiki 4.5.3)

Implemented on the server; see [API.md](API.md#dream-permissions). The app still needs the six switches and the "Keep out of AI processing" control.

`PUT /v1/dreams/{dream_id}/permissions` with any of `transcription`, `analysis`, `discussion`, `history`, `patterns`, `visuals` (booleans, each optional): 200 with `dream`. Only the fields sent change; the revision is not raised. The app's "Keep out of AI processing" control sends all six as false; turning it off sends nothing (wiki 4.5.8). The dream save keeps ignoring `permissions` after the first save.

## Summary and tag corrections (wiki 4.5.3)

`PUT /v1/dreams/{dream_id}/corrections` with `category` (`summary` or a tag category), `original_text` (for a tag), `text` (empty removes a tag; must not be empty for `summary`): 200 with `dream`. 409 `invalid_state` without a current organization, 400 when `original_text` matches no tag. Sending a tag's original text restores it. The story map has no card of its own for this; see open questions.

## Analysis (wiki 4.6.5)

`GET /v1/dreams/{dream_id}/analysis`: 200 with `analysis` (object or null) and `task` (the task the analysis waits for, else the newest `analyze` task of the present revision, else null).

`POST /v1/dreams/{dream_id}/analysis/refresh` with `refresh_id` (a UUID the app creates): 202 with `task` when scheduled, 200 with `task` when an existing task is returned. 403 when analysis is off, 409 when the text is empty, 429 at the cap.

```json
"analysis": {
  "id": "c2d4…", "status": "current", "dream_revision": 2,
  "sections": [{"kind": "waking_life_connections", "text": "…", "citations": ["DREAM", "M1"]}],
  "withheld": 0,
  "context": [
    {"label": "DREAM", "kind": "dream", "source_id": "9f1e…", "source_revision": 2, "source_date": "2026-10-12", "available": true, "cut_to": null},
    {"label": "M1", "kind": "memory", "source_id": "77aa…", "source_revision": 1, "source_date": "2026-10-01", "available": true, "cut_to": null}
  ],
  "removed_sources": 0,
  "dream_date": "2026-10-12", "mood": "calm",
  "model": "…", "instruction_version": "…", "created_at": 1760371200000
}
```

| Field | Values |
| --- | --- |
| `sections[].kind` | `what_happened`, `emotional_movement`, `waking_life_connections`, `themes_and_readings`, `threat_and_response`, `related_dreams`, `reflection_questions` |
| `context[].label` | `DREAM`, `DESC`, `ANALYSIS`, `NOTES`, or `M`/`D` followed by digits (a memory or another dream) |
| `context[].kind` | `dream`, `memory`, `output`, `notes` |
| `removed_sources` | Supplied sources deleted since, or excluded now; they have no `context` entry |

Swift types (wiki 4.6.7): `Analysis`, `AnalysisSection`, `SectionKind`, `ContextEntry`, `SourceKind`, `AnalysisResponse { analysis: Analysis?, task: TaskInfo? }`. Life notes appear as `memory` entries; a note whose `allow_analysis` is off is never supplied and drops out of older analyses at read time.

## Patterns (wiki 4.8.7)

All four routes return the patterns response and accept optional `from_date` and `to_date` (both or neither; the default period is the last 30 days in the user's time zone).

| Request | Body | Notes |
| --- | --- | --- |
| `GET /v1/patterns` | none | Calculated from stored rows |
| `PUT /v1/patterns/groups/{group_id}/label` | `label` (string or null; null or empty removes the user's label) | No AI call |
| `POST /v1/patterns/groups/{group_id}/dismiss` | `dream_id`, optional `note` | Repeating it changes only the note; an empty note removes it |
| `POST /v1/patterns/groups/{group_id}/split` | `dream_ids` (non-empty), optional `label`, optional `note` | A repeat answers 409; the app then calls `load()` |

```json
{
  "available": true,
  "period": {"from_date": "2026-09-14", "to_date": "2026-10-13"},
  "eligible_dreams": 12, "previous_eligible_dreams": 9,
  "findings": [{
    "group_id": "1a2b…", "label": "Being late for an exam", "label_corrected": false,
    "kind": "recurring", "status": "current", "explanation": "…",
    "supporting_dreams": 7, "period_count": 4, "previous_count": 2,
    "trend": "more_often_recorded_recently",
    "examples": [{"dream_id": "9f1e…", "dream_date": "2026-10-12", "title": "Exam", "category": "action",
                  "description": "running late to an exam", "excerpt": "I was late again", "shared_element": "…", "difference": null}],
    "notes": [], "dismissal_notes": [{"dream_id": "3c4d…", "note": "Different teacher"}]
  }],
  "insufficient_history": false,
  "task": null
}
```

| Field | Values |
| --- | --- |
| `available` | false when the server's vector extension is not loaded: stored findings still show, nothing new is matched |
| `kind` | `recurring` or `related` |
| `status` | `current`, or `refreshing` while the explanation is being rewritten (`explanation` is then null) |
| `trend` | `more_often_recorded_recently`, `less_often_recorded_recently`, `same`, or null |
| `task` | The user's newest `refresh_findings` task |

Swift types (wiki 4.8.10): `PatternsResponse`, `Period`, `Finding`, `FindingExample`, `DismissalNote`, `FindingKind`, `FindingStatus`, `Trend`. Counts are worded as "4 of 12 eligible recorded dreams" (`period_count` of `eligible_dreams`), never as how often the user dreams.

## Open questions for the team

- Pattern discovery was designed as a stretch goal (wiki Arc C) and is now Skeletal. Agree where the patterns screen sits in the app before the routes are built.
- Summary and tag corrections are part of the wiki's organization increment but have no story map card. Decide whether they are Skeletal.
- The wiki places patterns after organization and analysis, because they are built from checked tags and embeddings. Plan the patterns screen last even though it is Skeletal.
