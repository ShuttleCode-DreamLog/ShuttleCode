# DreamLog JSON API

This page lists implemented routes. Routes and fields that the remaining Skeletal cards need are agreed in [SkeletalContracts.md](SkeletalContracts.md).

Local origin: `https://127.0.0.1:8443`. The deployed course server uses the same paths at `https://34.66.84.214`. Every route below requires `Authorization: Bearer <lowercase UUID>`. The app stores its credential only in device-only Keychain. Standalone development clients should use their own test UUID; never copy or print a real user's credential.

Send `Content-Type: application/json` for JSON bodies. Timestamps are Unix milliseconds. IDs are lowercase UUIDs chosen by the client before saving and reused on retry. Unknown body fields do not grant access. Errors use `{"error":"code","message":"message","request_id":"…","current_revision":null}` and the `X-Request-ID` header; conflicts include the current revision.

| Resource | Read | Write | Delete |
| --- | --- | --- | --- |
| Device settings | `GET /v1/me` | `PUT /v1/me` | `DELETE /v1/me` deletes all owned data |
| Journal | `GET /v1/dreams`, `GET /v1/dreams/{id}` | `PUT /v1/dreams/{id}`, `PUT /v1/dreams/{id}/permissions` | `DELETE /v1/dreams/{id}` |
| Life notes | `GET /v1/memories`, `GET /v1/memories/{id}` | `PUT /v1/memories/{id}` | `DELETE /v1/memories/{id}` |
| Note photos | `GET /v1/memories/{id}/photos/{photo_id}` | `PUT /v1/memories/{id}/photos/{photo_id}` | `DELETE /v1/memories/{id}/photos/{photo_id}` |
| Profile | `GET /v1/me/profile` | `PUT /v1/me/profile` | Remove keys or send empty `fields`; whole-user deletion also clears it |
| AI tasks | In `dream.tasks` and journal `status` | `POST /v1/tasks/{id}/retry` | Deleted with their dream or the whole journal |

Lists return `{"items":[…],"has_more":false}`. Pass `limit` (1–200, default 50) and `offset` (default 0). Journal order is date descending, creation time descending, ID ascending; Notes order is recording time descending, ID ascending. Notes additionally accepts `ongoing=true` or `ongoing=false`.

## Journal

Create with `base_revision: 0`; edit with the last returned revision:

```json
{
  "base_revision": 0,
  "text": "Invented dream by a blue lake.",
  "dream_date": "2026-10-08",
  "title": "Lake",
  "mood": "calm",
  "source": "text"
}
```

Text and dream_date are required. Dates use real `YYYY-MM-DD` calendar dates. Source is required on creation and immutable afterwards. Optional title/mood: omission preserves, null clears; blank title becomes null. Mood values: calm, happy, excited, confused, sad, anxious, afraid, angry. Optional creation permissions: transcription, analysis, discussion, history, patterns and visuals, all booleans defaulting true. Stored permissions are preserved by this route; change them with the permissions route below.

Success: 201 on creation, 200 on update/repeat, `{"dream":{…}}`. The object contains `id`, `text`, `revision`, `dream_date`, `title`, `mood`, `source`, `audio_status`, `audio_ms`, `heard_text`, `permissions`, `tasks`, `organization`, `created_at`, `updated_at`. `tasks` and `organization` are described under AI tasks and Summary and tags below. Text limit: 20,000 characters; title: 120. Text must not be whitespace only. Text changes increase revision; metadata changes do not. A different text with a stale revision gets 409 `revision_conflict`.

Search: `POST /v1/dreams/search` with `{"query":"lake"}`. Optional mood, from_date, to_date and tag filters can be combined. This is literal case-insensitive SQLite title/text matching (non-ASCII case folding is limited); `%` and `_` are literal characters. Search text is sent in the body, not the URL. `tag` matches a dream's current tags after normalization (trimmed, lower case, single spaces), including the user's corrections. Unsent local drafts are not server search results.

Journal list items contain id, dream_date, title, mood, revision, audio_status, preview, summary, status, favorite_visual_id and updated_at. `summary` is the current organization's summary, or null; `favorite_visual_id` is null in this build.

## Dream permissions

`PUT /v1/dreams/{id}/permissions` changes the six AI switches of an owned dream:

```json
{"analysis": false, "history": false}
```

Each of `transcription`, `analysis`, `discussion`, `history`, `patterns` and `visuals` is an optional boolean; only the switches sent change. Send all six as false for the app's "Keep out of AI processing" control. `{}` or a repeat of the stored values changes nothing. Success is 200 with `{"dream":{…}}`. The text revision is not raised, so an open editor keeps saving with its revision; `updated_at` changes only when a switch changes. `null`, numbers, strings or a non-object body get 400; another user's or a missing dream gets 404. Unknown fields are ignored and never change other dream fields. No AI work exists yet, so a change has no further effect; the wiki 4.3.6 effects are marked as an `AI integration point` in `dreams.py`.

## Notes

Notes use the wiki's memory contract:

```json
{
  "base_revision": 0,
  "text": "Invented life note: preparing for exams.",
  "event_date": null,
  "event_precision": "unknown",
  "is_ongoing": false,
  "allow_analysis": true
}
```

Required: base_revision and text, at most 2,000 characters. Text may be empty for a photo note; whitespace-only text is rejected. A note without a date uses null + unknown. A dated note uses exact or approximate. New notes default to no date, not ongoing and analysis allowed; a supplied date defaults to exact. On editing, omitted optional fields retain their values: send both date and precision when changing/removing a date. checkin_id is read-only and cannot be set by this endpoint.

Success: 201 on creation, 200 on update/repeat, `{"memory":{…}}`. Its fields are id, text, recorded_at, event_date, event_precision, is_ongoing, allow_analysis, checkin_id, revision, updated_at and photos. recorded_at never changes. A change to text/date/precision/ongoing raises the revision. A permission-only change keeps it. On a stale content edit, 409 preserves the content but applies an explicitly supplied analysis permission; reload before resolving the conflict. This permission is saved for later AI features and causes no AI call now.

## Note photos

Create the note first, then PUT raw image bytes to `/v1/memories/{id}/photos/{photo_id}` with the same Bearer header and `Content-Type: image/jpeg` or `image/png`. A note supports at most 5 photos, at most 5 MB per photo. IDs are client-generated and reused on retry; a photo ID cannot be moved between notes. Basic format framing and size are checked; the backend does not decode or re-encode images.

Upload returns 201 new / 200 repeated with `{"photo":{"id":"…","content_type":"image/jpeg","byte_count":123,"created_at":123}}`. Memory objects include a photos array of that metadata. GET returns raw bytes with the stored image content type and Cache-Control: no-store. DELETE returns 204, or 404 for a missing/foreign photo. Note/user deletion cascades attachments atomically. Photo changes do not change the note text revision; photos are not currently AI inputs.

```sh
curl --cacert backend/.local/server.crt \
  -H 'Authorization: Bearer <test-user-uuid>' \
  -H 'Content-Type: image/jpeg' \
  -X PUT https://127.0.0.1:8443/v1/memories/<note-uuid>/photos/<photo-uuid> \
  --data-binary @sample.jpg
```

The native app downsizes selected images and uploads JPEG. Text save and each attachment upload are separate; a failed upload does not undo already-saved text/photos. See [EditorAndPhotos.md](EditorAndPhotos.md) for retry behavior and explicit future AI integration points.

## Profile

Read: `{"profile":{"fields":{},"revision":0,"updated_at":null}}` before any save. Write:

```json
{
  "base_revision": 0,
  "fields": {"name":"Sample Person","age":"21","city":"Ann Arbor","favorite_color":"blue"}
}
```

Success: 200 with the same profile envelope. This replaces the complete fields dictionary. Omitted keys and blank values are removed; `fields:{}` clears all values. Changes increment revision; a stale changed dictionary gets 409, while an identical retry is unchanged. Profiles are independent of `/v1/me` updates.

All values are strings of at most 200 characters. Keys follow `[a-z][a-z0-9_]{0,39}`; at most 30 keys. Values are trimmed. Age, when present, is a whole number string from 0 through 150. Extra ordinary keys need no database change. Profile fields are not AI inputs.

## AI tasks

AI work runs in the backend's task worker, never inside a request. One type is scheduled so far: `organize`, for each new text revision of a text dream whose `analysis` switch is on, and again when that switch is turned on. Other types start with their handlers; the shapes below are final.

Task object, as it appears in `dream.tasks`:

```json
{"id": "5b0c…", "type": "organize", "status": "failed", "error_code": "network", "dream_id": "9f1e…", "subject_id": null, "source_revision": 2, "updated_at": 1760371200000}
```

`type` is one of `transcribe`, `organize`, `analyze`, `index_dream`, `match_patterns`, `refresh_findings`, `generate_image`, `generate_video`; `status` is `waiting`, `running`, `completed`, `failed`, `canceled` or `obsolete`. `error_code` is set when `failed`, or `waiting` after a failed attempt; it names a category, never content. `dream.tasks` holds, for the dream's present revision, the newest task of each type (a `transcribe` task always counts; generation tasks are left out), so it is `[]` until work exists.

Journal items' `status` is `attention` when the newest `transcribe`, `organize` or `analyze` task of the present revision failed (a `provider_refused` organization or analysis leaves no mark), otherwise `processing` while one is `waiting` or `running`, otherwise `ready`.

There is no push and no list of tasks: the app reads them with the record, when a screen opens, the app returns to the foreground, or the user pulls to refresh.

`POST /v1/tasks/{id}/retry`, no body: 200 with `{"task":{…}}`. A `failed` task returns to `waiting` with its attempts reset; a `waiting` or `running` one is returned unchanged, so repeating the request is harmless. `completed`, `canceled` or `obsolete` get 409 `invalid_state`; another user's or a missing task 404. While the daily limit for the task's kind of work is used up, a retry gets 429 with `cap_reached` (this user) or `ceiling_reached` (all users); the limits reset at 00:00 UTC and `GET /v1/me` shows today's `usage`.

The worker claims at most three attempts per task, waiting 15 s and 60 s between them, or 60 s and 300 s after `rate_limited` and `provider_config`; then the task is `failed` until the user retries it. A server restart resumes interrupted work, and tasks that failed with `provider_config` (a key or model fault) start again.

## Summary and tags

When `organize` completes, `dream.organization` holds the result for the revision it was made from:

```json
{"status": "current", "dream_revision": 2, "summary": "A night walk by a blue lake.", "summary_corrected": false,
 "tags": [{"category": "place", "text": "blue lake", "original_text": "blue lake", "excerpt": "by the Blue Lake", "feeling": null, "corrected": false, "removed": false}],
 "created_at": 1760371200000}
```

It is `null` until the first result. After a text edit it stays visible with `status` `outdated` until the new revision is organized; the journal `summary` is null meanwhile. `category` is `person`, `place`, `object`, `action`, `emotion` or `theme`; `feeling` is `stated` or `inferred` for an emotion and null otherwise. Every excerpt is a passage of the dream text as written, checked by the backend; items without a matching excerpt are dropped, labels are lower case, and at most 30 tags are kept. `corrected`, `removed` and `summary_corrected` reflect the user's corrections; the corrections route itself is not built yet. Only the dream text is sent to Gemini, never the title, mood or notes, and the daily `text` limit counts each attempt.

## Device settings and deletion

`GET /v1/me` returns user_id, timezone, reminder_weekday, use_history, limits, usage and checkin_keep_days. The UUID is a credential and is not displayed by the app. `PUT /v1/me` accepts partial timezone, reminder_weekday (1–7 or null) and use_history; omitted fields remain unchanged. An unknown timezone is ignored. The app's timezone alignment preserves server history and cannot modify Profile.

DELETE success is 204 with no body. A missing individual note/journal returns 404; clients may treat this as already deleted after user confirmation. Whole-user deletion clears all owned database rows and journal files. Missing or invalid credentials get 401. Invalid bodies get 400, excessive size 413, stale content 409, unexpected failures a sanitized 500.

## Call from a collaborator's terminal

From the repository root, with the local backend running, substitute your own test credential and entry ID:

```sh
curl --cacert backend/.local/server.crt \
  -H 'Authorization: Bearer <test-user-uuid>' \
  -H 'Content-Type: application/json' \
  -X PUT https://127.0.0.1:8443/v1/memories/<note-uuid> \
  --data '{"base_revision":0,"text":"Invented sample note."}'

curl --cacert backend/.local/server.crt \
  -H 'Authorization: Bearer <test-user-uuid>' \
  https://127.0.0.1:8443/v1/memories
```

Use the returned revision on edit. Use the same credential and ID for GET/DELETE. A separate test UUID has separate settings, profile, journals and notes. The runnable smoke test `backend/tests/smoke_https.py` exercises these operations with invented data and deletes its temporary user afterwards.
