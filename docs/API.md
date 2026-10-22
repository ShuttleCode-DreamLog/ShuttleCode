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
| Analysis | `GET /v1/dreams/{id}/analysis` | `POST /v1/dreams/{id}/analysis/refresh` | Deleted with its dream |
| Patterns | `GET /v1/patterns` | `PUT /v1/patterns/groups/{id}/label`, `POST …/dismiss`, `POST …/split` | Groups without members, corrections or a user label are removed by the next refresh |

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

Search: `POST /v1/dreams/search` with `{"query":"a quiet lake","tags":["lake"],"mood":"calm"}`. Optional `tags` (every listed tag must be among the dream's current tags, after normalization: trimmed, lower case, single spaces, with the user's corrections), `mood`, `from_date` and `to_date` narrow the dreams; the older single `tag` field still works. `query` then ranks the narrowed dreams by meaning: the wording is embedded once (one unit of the day's text allowance) and compared with each dream's vector, dreams within `SEARCH_MAX_DISTANCE` (cosine distance 0.42, measured on 21 October 2026) are returned closest first with their `similarity` (1 − distance), and a dream that carries the words literally but has no vector (its patterns switch is off, or it is not indexed yet) follows them with `similarity` null. The response's `ranked` is true then. When the vector extension is missing, the allowance is used up or the embedding call fails, `ranked` is false and the search is literal case-insensitive SQLite title/text matching in journal order (non-ASCII case folding is limited; `%` and `_` are literal characters). Search text is sent in the body, not the URL. Unsent local drafts are not server search results.

Tags to filter by: `GET /v1/tags` returns `{"tags":[{"category":"place","text":"blue lake","count":2}]}`, every effective tag of the user's current organizations with the number of dreams carrying it, most frequent first.

Journal list items contain id, dream_date, title, mood, revision, audio_status, preview, summary, tags, similarity, status, favorite_visual_id and updated_at. `summary` is the current organization's summary, or null; `tags` are its effective tags as `{"category","text"}` in the order they were found, with the user's corrections applied and removed tags left out, or `[]`; `favorite_visual_id` is null in this build.

## Dream permissions

`PUT /v1/dreams/{id}/permissions` changes the six AI switches of an owned dream:

```json
{"analysis": false, "history": false}
```

Each of `transcription`, `analysis`, `discussion`, `history`, `patterns` and `visuals` is an optional boolean; only the switches sent change. Send all six as false for the app's "Keep out of AI processing" control. `{}` or a repeat of the stored values changes nothing. Success is 200 with `{"dream":{…}}`. The text revision is not raised, so an open editor keeps saving with its revision; `updated_at` changes only when a switch changes. `null`, numbers, strings or a non-object body get 400; another user's or a missing dream gets 404. Unknown fields are ignored and never change other dream fields. A change takes effect at once (wiki 4.3.6): turning `history` off removes the sections of other dreams' analyses that cited this dream and marks those analyses `outdated`; turning `analysis` or `patterns` off takes the dream out of its pattern groups and refreshes the findings; turning a switch on, or `analysis` off, schedules the dream's processing again as its switches allow. `transcription` has no effect until voice capture.

## Notes

Notes use the wiki's memory contract:

```json
{
  "base_revision": 0,
  "title": "Exam week",
  "text": "Invented life note: preparing for exams.",
  "event_date": null,
  "event_precision": "unknown",
  "is_ongoing": false,
  "allow_analysis": true
}
```

Required: base_revision and text, at most 2,000 characters. Text may be empty for a photo note; whitespace-only text is rejected. Optional title, at most 120 characters: omission preserves it, null or blank clears it (schema version 6). A note without a date uses null + unknown. A dated note uses exact or approximate. New notes default to no date, not ongoing and analysis allowed; a supplied date defaults to exact. On editing, omitted optional fields retain their values: send both date and precision when changing/removing a date. checkin_id is read-only and cannot be set by this endpoint.

Success: 201 on creation, 200 on update/repeat, `{"memory":{…}}`. Its fields are id, title, text, recorded_at, event_date, event_precision, is_ongoing, allow_analysis, checkin_id, revision, updated_at and photos. recorded_at never changes. A change to title/text/date/precision/ongoing raises the revision. A permission-only change keeps it. On a stale content edit, 409 preserves the content but applies an explicitly supplied analysis permission; reload before resolving the conflict. With it on, and the account's history switch on, the note can be context for dream analyses; turning it off removes the analysis sections that cited the note and marks those analyses `outdated`, while a content change only marks them `outdated`. Neither starts an AI call.

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

AI work runs in the backend's task worker, never inside a request. Each new text revision of a text dream whose `analysis` switch is on schedules `organize`, and `analyze` once organization has ended; with `patterns` on, `index_dream` and `match_patterns` follow and `refresh_findings` updates the findings (Pattern discovery below). `transcribe`, `generate_image` and `generate_video` arrive with their increments; the shapes below are final.

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

It is `null` until the first result. After a text edit it stays visible with `status` `outdated` until the new revision is organized; the journal `summary` is null meanwhile. `category` is `person`, `place`, `object`, `action`, `emotion` or `theme`; `feeling` is `stated` or `inferred` for an emotion and null otherwise. Every excerpt is a passage of the dream text as written, checked by the backend; items without a matching excerpt are dropped, labels are lower case, and at most 30 tags are kept. `corrected`, `removed` and `summary_corrected` reflect the user's corrections (below). Only the dream text is sent to Gemini, never the title, mood or notes, and the daily `text` limit counts each attempt.

## Correcting the summary and tags

`PUT /v1/dreams/{id}/corrections` changes what the current organization says, without changing the dream:

```json
{"category": "person", "original_text": "teacher", "text": "my aunt"}
{"category": "summary", "text": "My own summary."}
```

`category` is `summary` or a tag category; a tag correction names the tag by its `original_text` (from `organization.tags`). `text` is the new wording, normalized like a tag (trimmed, lower case, single spaces); an empty `text` removes the tag, and sending the tag's original text, or the generated summary, takes the correction back. A rename to the present text of another tag of the same category removes the tag instead, so no tag appears twice. Repeating a request changes nothing. Success is 200 with `{"dream":{…}}`. 409 `invalid_state` without a current organization (none yet, or outdated after a text edit), 400 for an unknown category, a missing `original_text` or one that matches no tag, or an empty summary, 413 over 60 characters for a tag or 600 for a summary.

Corrections are kept apart from the generated rows, so a retry or a new organization never overwrites them, and they are dropped with the organization when the dream's text changes. Each change raises the organization's revision, marks analyses that were given the description as outdated, and, for a tag, removes the tag from its pattern group (its texts are rewritten at the next refresh) and indexes and matches the dream again from the corrected text. A summary correction schedules no new work.

## Analysis

After `organize` ends (completed, or failed for any reason but a limit), the worker runs `analyze` once per revision. `GET /v1/dreams/{id}/analysis` returns `{"analysis": {…} or null, "task": {…} or null}`; `task` is the work the analysis waits for (transcript, summary or analysis of the present revision), otherwise the newest `analyze` task.

```json
{"id": "c2d4…", "status": "current", "dream_revision": 2,
 "sections": [{"kind": "waking_life_connections", "text": "The deadline may echo the rush.", "citations": ["DREAM", "M1"]}],
 "withheld": 0, "removed_sources": 0, "dream_date": "2026-10-15", "mood": "anxious", "model": "gemini-3.1-flash-lite", "instruction_version": "analyze-1", "created_at": 1760371200000,
 "context": [{"label": "DREAM", "kind": "dream", "source_id": "9f1e…", "source_revision": 2, "source_date": "2026-10-15", "available": true, "cut_to": null},
             {"label": "M1", "kind": "memory", "source_id": "77aa…", "source_revision": 1, "source_date": "2026-10-13", "available": true, "cut_to": null}]}
```

Section kinds, in stored order: `what_happened` and `reflection_questions` (always), `emotional_movement`, `waking_life_connections` (only with a life note), `themes_and_readings`, `threat_and_response`, `related_dreams` (only with an earlier dream). Every citation was checked against the supplied labels; sections that failed even after one repair call are left out and counted in `withheld`. Context: `DREAM`, `DESC` (summary and tags), up to 4 life notes (`M1`…) chosen by shared terms and date windows, and up to 3 earlier dreams (`D1`…) that share at least two terms; none of the notes or earlier dreams when the history switch in Settings is off, or when a note's or dream's own switch excludes it. The title is never sent. `available` is false once a source has changed; a source excluded now has no entry and is counted in `removed_sources`, as is a deleted one.

`status` becomes `outdated` when the dream's text, mood or date changes or a source changes. Excluding a note (its "Allow future AI context" off) or an earlier dream (its `history` switch off) removes the sections that cite it; deleting it removes every section. The user then refreshes: `POST /v1/dreams/{id}/analysis/refresh` with `{"refresh_id": "<new UUID>"}` answers 202 with the scheduled `task`, or 200 with work already on its way or the task of a repeated `refresh_id`; 403 `not_permitted` when the dream's `analysis` switch is off, 409 when it has no text, 429 at the daily limit.

## Patterns

Pattern discovery runs by itself: after organization, `index_dream` embeds the dream and its tags (inferred emotions excluded), `match_patterns` asks Gemini whether each new tag joins a candidate group, starts one with a similar ungrouped tag of another dream, or stays alone, and `refresh_findings` writes each group's label, description and explanation. Candidates come only from the same user, from identical tags and from tags within cosine distance 0.40 (sqlite-vector); distance never creates a membership, the model must name a specific shared element. Every number is counted by the backend.

`GET /v1/patterns` (optional `from_date` and `to_date`, both or neither; default the last 30 days in the user's time zone):

```json
{"available": true, "period": {"from_date": "2026-09-16", "to_date": "2026-10-15"}, "eligible_dreams": 5, "previous_eligible_dreams": 0,
 "findings": [{"group_id": "1a2b…", "label": "Missed transit", "label_corrected": false, "kind": "recurring", "status": "current",
               "explanation": "…3 recorded dreams…", "supporting_dreams": 3, "period_count": 3, "previous_count": 0, "trend": null,
               "examples": [{"dream_id": "9f1e…", "dream_date": "2026-10-13", "title": null, "category": "action", "description": "missing the bus",
                             "excerpt": "The bus kept leaving", "shared_element": "a vehicle departing just before arrival", "difference": null}],
               "notes": [], "dismissal_notes": []}],
 "insufficient_history": false, "task": {…}}
```

`kind` is `recurring` from 3 supporting dreams, `related` from 2; smaller groups are not shown, and `insufficient_history` is true without findings. `supporting_dreams` counts distinct dreams; `period_count` of `eligible_dreams` (dreams with text whose `patterns` and `analysis` switches are on, dated in the period) and the previous period of equal length give `trend` (`more_often_recorded_recently`, `less_often_recorded_recently`, `same`, or null). `status` is `refreshing`, with `explanation` null, while the evidence differs from what the explanation was written for; opening the screen then schedules one refresh unless that evidence was already tried or the newest refresh failed. `available` is false when the server's vector extension did not load: stored findings still show, nothing new is matched.

All three actions return the patterns response. `PUT …/label` with `{"label": "…"}` sets the user's own label (null or empty removes it; at most 60 characters); it is never sent to the AI. `POST …/dismiss` with `{"dream_id": "…", "note": "…"}` removes the dream from the group for good: it is never matched back into that group, nor grouped again with the group's other dreams; repeating it changes only the note, and an empty note removes it. 409 when the dream does not support the group. `POST …/split` with `{"dream_ids": […], "label": "…", "note": "…"}` moves those dreams into a new group and keeps both sides apart from then on; 409 unless every listed dream supports the group and one remains, so a repeat answers 409. Notes are at most 300 characters (413) and are sent with the group to later matching while the dream they name is not excluded. Editing a member dream, turning its `patterns` or `analysis` switch off, or deleting it removes the AI-written texts of its groups at once; deleting it also empties the notes of splits it took part in.

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
