import os
from datetime import datetime, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import msgspec
from starlette.responses import Response
import db
import config
import tasks
from web import RequestError, json_response, read_body, resolve_user


async def save_output(connection, identity, dream_id, output_type, dream_revision, content, model, instruction_version, sources=()):
    # A generation is a new record with a new ID, not an upsert: the old output's tags and corrections must go with it (wiki 4.3.4).
    for row in await connection.execute_fetchall("SELECT id FROM outputs WHERE dream_id=? AND type=?", (dream_id, output_type)):
        await connection.execute("UPDATE outputs SET status='outdated' WHERE id=?", (row["id"],))
        await source_changed(connection, "output", row["id"])
    output_id = str(uuid4())
    await connection.execute("INSERT INTO outputs(id,user_id,dream_id,type,dream_revision,content,model,instruction_version,created_at) VALUES(?,?,?,?,?,?,?,?,?)", (output_id, identity, dream_id, output_type, dream_revision, msgspec.json.encode(content).decode(), model, instruction_version, config.now()))
    await connection.executemany("INSERT INTO sources(id,user_id,output_id,label,kind,source_id,source_revision,source_date,cut_to) VALUES(?,?,?,?,?,?,?,?,?)", [(str(uuid4()), identity, output_id, *source) for source in sources])
    await connection.execute("DELETE FROM outputs WHERE dream_id=? AND type=? AND id<>?", (dream_id, output_type, output_id))
    return output_id


async def source_changed(connection, kind, source_id):
    await connection.execute("UPDATE outputs SET status='outdated' WHERE id IN (SELECT output_id FROM sources WHERE kind=? AND source_id=? AND output_id IS NOT NULL)", (kind, source_id))
    # AI integration point: from the discussion increment, also mark stale every discussion whose ok reply has such a sources row.
    # Later replies were written with the earlier ones in view, so the whole discussion goes stale, not one reply (wiki 4.3.5).
    await connection.execute("UPDATE messages SET state='stale' WHERE dream_id IN (SELECT r.dream_id FROM sources s JOIN messages r ON r.id=s.message_id WHERE s.kind=? AND s.source_id=? AND r.state='ok')", (kind, source_id))


async def source_removed(connection, kind, source_id, deleted):
    # An exclusion removes only the sections resting on the source and keeps its rows, so a later deletion still finds every record (wiki 4.3.5).
    for row in await connection.execute_fetchall("SELECT s.output_id,s.label,o.content FROM sources s JOIN outputs o ON o.id=s.output_id WHERE s.kind=? AND s.source_id=?", (kind, source_id)):
        content = msgspec.json.decode(row["content"])
        content["sections"] = [] if deleted else [section for section in content.get("sections", []) if row["label"] not in section["citations"]]
        content["removed_sources"] = content.get("removed_sources", 0) + int(deleted)
        await connection.execute("UPDATE outputs SET status='outdated',content=? WHERE id=?", (msgspec.json.encode(content).decode(), row["output_id"]))
    # AI integration point: from the discussion increment, also mark stale or trim the discussions whose replies were given the source.
    # This reads the sources rows, so it runs before a deletion removes them.
    for row in await connection.execute_fetchall("SELECT r.dream_id,MIN(r.seq) AS first,MAX(r.state='ok') AS used FROM sources s JOIN messages r ON r.id=s.message_id WHERE s.kind=? AND s.source_id=? AND r.dream_id IS NOT NULL GROUP BY r.dream_id", (kind, source_id)):
        if deleted:
            await connection.execute("DELETE FROM messages WHERE dream_id=? AND role='assistant' AND seq>=?", (row["dream_id"], row["first"]))
        if deleted or row["used"]:
            await connection.execute("UPDATE messages SET state='stale' WHERE dream_id=?", (row["dream_id"],))
    if deleted:
        await connection.execute("DELETE FROM sources WHERE kind=? AND source_id=?", (kind, source_id))


async def dream_text_changed(connection, dream_id):
    await connection.execute("UPDATE outputs SET status='outdated' WHERE dream_id=?", (dream_id,))
    await connection.execute("UPDATE messages SET state='stale' WHERE dream_id=?", (dream_id,))
    await source_changed(connection, "dream", dream_id)
    # A foundation module imports a component module only inside the calling function (wiki 4.1.1, rule 4).
    import patterns
    await patterns.clear_dream_groups(connection, dream_id)
    owner = await connection.execute_fetchall("SELECT user_id FROM dreams WHERE id=?", (dream_id,))
    if owner:
        await patterns.schedule_refresh(connection, owner[0]["user_id"])
    # AI integration point: discussion staleness and visual versions join here in their increments (wiki 4.3.5).


async def description_revision(connection, dream):
    # The organization made for the present revision, or 0: a tag or summary correction raises it and so makes indexing new work (wiki 4.3.3, note 3).
    rows = await connection.execute_fetchall("SELECT revision FROM outputs WHERE dream_id=? AND type='organization' AND dream_revision=?", (dream["id"], dream["revision"]))
    return rows[0]["revision"] if rows else 0


def index_version():
    return f"{os.environ.get('EMBEDDING_MODEL', '')}:{config.EMBEDDING_DIMENSIONS}"


async def schedule_processing(connection, dream_id, run_after=None):
    rows = await connection.execute_fetchall("SELECT * FROM dreams WHERE id=?", (dream_id,))
    if not rows:
        return
    dream = rows[0]
    # Organizing waits while recorded audio may still become the text, so a voice dream is organized once (wiki 4.3.6, rule 2).
    pending = dream["audio_status"] in ("expected", "uploaded") and dream["allow_transcription"] and not await connection.execute_fetchall("SELECT 1 FROM tasks WHERE dream_id=? AND type='transcribe' AND status='failed' AND error_code NOT IN ('cap_reached','ceiling_reached')", (dream_id,))
    ready = bool(dream["text"]) and not pending
    # Organization of this revision has ended when its output exists or its task failed for a reason other than a limit.
    ended = await connection.execute_fetchall("SELECT 1 FROM outputs WHERE dream_id=? AND type='organization' AND dream_revision=? UNION ALL SELECT 1 FROM tasks WHERE request_key=? AND status='failed' AND error_code NOT IN ('cap_reached','ceiling_reached')", (dream_id, dream["revision"], f"organize:{dream_id}:{dream['revision']}"))
    if ready and dream["allow_analysis"]:
        await tasks.schedule(connection, "organize", f"organize:{dream_id}:{dream['revision']}", dream["user_id"], dream_id, None, dream["revision"])
        # Analysis waits until organization of this revision has ended, so it can use the summary and tags; a limit holds both back (rule 3).
        if ended:
            await tasks.schedule(connection, "analyze", f"analyze:{dream_id}:{dream['revision']}:initial", dream["user_id"], dream_id, None, dream["revision"])
    # Indexing follows organization, or starts at once when analysis is off and organization will not run (rule 4).
    if ready and dream["allow_patterns"] and (ended or not dream["allow_analysis"]):
        state = f"{dream_id}:{dream['revision']}:{await description_revision(connection, dream)}"
        await tasks.schedule(connection, "index_dream", f"index_dream:{state}:{index_version()}", dream["user_id"], dream_id, None, dream["revision"], run_after)
        if dream["allow_analysis"] and await connection.execute_fetchall("SELECT 1 FROM tasks WHERE request_key=? AND status='completed'", (f"index_dream:{state}:{index_version()}",)):
            await tasks.schedule(connection, "match_patterns", f"match_patterns:{state}", dream["user_id"], dream_id, None, dream["revision"])
    # AI integration point: rule 1 (transcribe) is added with voice capture (wiki 4.1, rule 6).


def utc_day():
    return datetime.fromtimestamp(config.now() / 1000, timezone.utc).date().isoformat()


async def limit_reached(connection, identity, kind, day):
    counts = {r["user_id"]: r["count"] for r in await connection.execute_fetchall("SELECT user_id,count FROM usage WHERE user_id IN (?,'all') AND day=? AND kind=?", (identity, day, kind))}
    return "cap_reached" if counts.get(identity, 0) >= config.CAPS[kind] else "ceiling_reached" if counts.get("all", 0) >= config.CEILINGS[kind] else None


async def is_cap_reached(identity, kind):
    return await limit_reached(db.rwdb, identity, kind, utc_day())


async def charge(identity, kind):
    day = utc_day()
    async with db.tx() as connection:
        reached = await limit_reached(connection, identity, kind, day)
        if reached is None:
            # A charge that arrives just after the journal was deleted must not recreate the user's counter.
            await connection.execute("INSERT INTO usage(user_id,day,kind,count) SELECT ?,?,?,1 WHERE EXISTS(SELECT 1 FROM users WHERE id=?) ON CONFLICT(user_id,day,kind) DO UPDATE SET count=count+1", (identity, day, kind, identity))
            await connection.execute("INSERT INTO usage(user_id,day,kind,count) VALUES('all',?,?,1) ON CONFLICT(user_id,day,kind) DO UPDATE SET count=count+1", (day, kind))
    return reached


async def me_value(identity):
    rows = await db.rwdb.execute_fetchall("SELECT * FROM users WHERE id=?", (identity,))
    if not rows:
        raise RequestError(404, "not_found", "Journal no longer exists.")
    row = rows[0]
    day = utc_day()
    usage = {r["kind"]: r["count"] for r in await db.rwdb.execute_fetchall("SELECT kind,count FROM usage WHERE user_id=? AND day=?", (identity, day))}
    return {"user_id": identity, "timezone": row["timezone"], "reminder_weekday": row["reminder_weekday"], "use_history": bool(row["use_history"]), "limits": config.LIMITS, "usage": [{"kind": kind, "used": usage.get(kind, 0), "cap": cap} for kind, cap in config.CAPS.items()], "checkin_keep_days": config.CHECKIN_KEEP_DAYS}


async def get_me(request):
    return json_response(await me_value(await resolve_user(request)))


class SettingsUpdate(msgspec.Struct):
    timezone: str | msgspec.UnsetType = msgspec.UNSET
    reminder_weekday: int | None | msgspec.UnsetType = msgspec.UNSET
    use_history: bool | msgspec.UnsetType = msgspec.UNSET


async def put_me(request):
    identity = await resolve_user(request)
    fields = await read_body(request, SettingsUpdate)
    changes = {}
    if fields.timezone is not msgspec.UNSET:
        try:
            ZoneInfo(fields.timezone)
            changes["timezone"] = fields.timezone
        except (ZoneInfoNotFoundError, ValueError):
            pass
    if fields.reminder_weekday is not msgspec.UNSET:
        weekday = fields.reminder_weekday
        if weekday is not None and (type(weekday) is not int or not 1 <= weekday <= 7):
            raise RequestError(400, "invalid_request", "Reminder weekday must be 1 through 7 or null.")
        changes["reminder_weekday"] = weekday
    if fields.use_history is not msgspec.UNSET:
        changes["use_history"] = int(fields.use_history)
    if changes:
        async with db.tx() as connection:
            before = await connection.execute_fetchall("SELECT use_history FROM users WHERE id=?", (identity,))
            # Column names come solely from the fixed allowlist above.
            await connection.execute(f"UPDATE users SET {','.join(f'{column}=?' for column in changes)} WHERE id=?", (*changes.values(), identity))
            if before and before[0]["use_history"] and changes.get("use_history") == 0:
                # Discussions that drew on a note or an earlier dream, directly or through their analysis, start afresh (wiki 4.3.6).
                await connection.execute("UPDATE messages SET state='stale' WHERE dream_id IN (SELECT r.dream_id FROM sources s JOIN messages r ON r.id=s.message_id WHERE s.kind IN ('memory','dream') AND r.state='ok' AND r.user_id=?)", (identity,))
    return json_response(await me_value(identity))


async def delete_me(request):
    identity = await resolve_user(request)
    async with db.tx() as connection:
        dreams = await connection.execute_fetchall("SELECT id FROM dreams WHERE user_id=?", (identity,))
        await connection.execute("DELETE FROM usage WHERE user_id=?", (identity,))
        await connection.execute("DELETE FROM users WHERE id=?", (identity,))
    directory = request.app.state.data_dir
    for dream in dreams:
        for path in (directory / "audio").glob(f"{dream['id']}.*"):
            path.unlink(missing_ok=True)
    return Response(status_code=204)
