from datetime import datetime, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import msgspec
from starlette.responses import Response
import db
import config
from web import RequestError, json_response, read_body, resolve_user


async def me_value(identity):
    rows = await db.rwdb.execute_fetchall("SELECT * FROM users WHERE id=?", (identity,))
    if not rows:
        raise RequestError(404, "not_found", "Journal no longer exists.")
    row = rows[0]
    day = datetime.fromtimestamp(config.now() / 1000, timezone.utc).date().isoformat()
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
            # Column names come solely from the fixed allowlist above.
            await connection.execute(f"UPDATE users SET {','.join(f'{column}=?' for column in changes)} WHERE id=?", (*changes.values(), identity))
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
