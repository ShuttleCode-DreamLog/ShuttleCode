import msgspec
from starlette.responses import Response
import config
import db
from dreams import check_date, paging
from photos import memory_photos
from web import RequestError, check_id, json_response, read_body, resolve_user


class MemorySave(msgspec.Struct, kw_only=True):
    base_revision: int
    text: str
    event_date: str | None | msgspec.UnsetType = msgspec.UNSET
    event_precision: str | msgspec.UnsetType = msgspec.UNSET
    is_ongoing: bool | msgspec.UnsetType = msgspec.UNSET
    allow_analysis: bool | msgspec.UnsetType = msgspec.UNSET


def memory_value(row):
    return {**{key: row[key] for key in ('id', 'text', 'recorded_at', 'event_date', 'event_precision', 'checkin_id', 'revision', 'updated_at')}, 'is_ongoing': bool(row['is_ongoing']), 'allow_analysis': bool(row['allow_analysis'])}


async def owned_memory(identity, memory_id):
    rows = await db.rwdb.execute_fetchall('SELECT * FROM memories WHERE id=? AND user_id=?', (memory_id, identity))
    if not rows:
        raise RequestError(404, 'not_found', 'Note not found.')
    return rows[0]


async def get_memory(request):
    identity = await resolve_user(request)
    memory_id = check_id(request.path_params['memory_id'])
    value = memory_value(await owned_memory(identity, memory_id))
    value['photos'] = await memory_photos(identity, memory_id)
    return json_response({'memory': value})


async def list_memories(request):
    identity = await resolve_user(request)
    limit, offset = paging(request)
    ongoing = request.query_params.get('ongoing')
    if ongoing not in (None, 'true', 'false'):
        raise RequestError(400, 'invalid_request', 'Ongoing must be true or false.')
    clause = '' if ongoing is None else ' AND is_ongoing=?'
    values = (identity,) if ongoing is None else (identity, int(ongoing == 'true'))
    rows = await db.rwdb.execute_fetchall(f'SELECT * FROM memories WHERE user_id=?{clause} ORDER BY recorded_at DESC,id ASC LIMIT ? OFFSET ?', (*values, limit + 1, offset))
    items = [memory_value(row) for row in rows[:limit]]
    photo_rows = await db.rwdb.execute_fetchall(f"SELECT id,memory_id,content_type,length(content) AS byte_count,created_at FROM memory_photos WHERE user_id=? AND memory_id IN ({','.join('?' for _ in items)}) ORDER BY created_at,id", (identity, *(item['id'] for item in items))) if items else []
    by_memory = {}
    for row in photo_rows:
        by_memory.setdefault(row['memory_id'], []).append({key: row[key] for key in ('id','content_type','byte_count','created_at')})
    for item in items:
        item['photos'] = by_memory.get(item['id'], [])
    return json_response({'items': items, 'has_more': len(rows) > limit})


async def save_memory(request):
    identity = await resolve_user(request)
    memory_id = check_id(request.path_params['memory_id'])
    body = await read_body(request, MemorySave)
    if body.base_revision < 0 or (body.text and not body.text.strip()):
        raise RequestError(400, 'invalid_request', 'Use a nonnegative revision; text cannot consist only of whitespace.')
    if len(body.text) > config.LIMITS['max_memory_chars']:
        raise RequestError(413, 'too_large', 'Note text is too long.')
    conflict = None
    async with db.tx() as connection:
        rows = await connection.execute_fetchall('SELECT * FROM memories WHERE id=? AND user_id=?', (memory_id, identity))
        stored = rows[0] if rows else None
        if stored is None and body.base_revision > 0:
            raise RequestError(404, 'not_found', 'Note not found.')
        event_date = (stored['event_date'] if stored else None) if body.event_date is msgspec.UNSET else body.event_date
        precision = (stored['event_precision'] if stored else 'exact' if event_date else 'unknown') if body.event_precision is msgspec.UNSET else body.event_precision
        if event_date is not None:
            check_date(event_date)
        if precision not in ('exact', 'approximate', 'unknown') or (precision == 'unknown') != (event_date is None):
            raise RequestError(400, 'invalid_request', 'Date and precision must agree; use null with unknown for no date.')
        ongoing = stored['is_ongoing'] if stored and body.is_ongoing is msgspec.UNSET else False if body.is_ongoing is msgspec.UNSET else body.is_ongoing
        allowed = stored['allow_analysis'] if stored and body.allow_analysis is msgspec.UNSET else True if body.allow_analysis is msgspec.UNSET else body.allow_analysis
        changed = stored is None or any((body.text != stored['text'], event_date != stored['event_date'], precision != stored['event_precision'], ongoing != stored['is_ongoing']))
        if stored and changed and body.base_revision != stored['revision']:
            conflict = stored['revision']
            if allowed != stored['allow_analysis']:
                await connection.execute('UPDATE memories SET allow_analysis=?,updated_at=? WHERE id=? AND user_id=?', (int(allowed), config.now(), memory_id, identity))
        elif changed or allowed != stored['allow_analysis']:
            timestamp = config.now()
            await connection.execute('''INSERT INTO memories(id,user_id,text,recorded_at,event_date,event_precision,is_ongoing,allow_analysis,revision,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET text=excluded.text,event_date=excluded.event_date,event_precision=excluded.event_precision,is_ongoing=excluded.is_ongoing,allow_analysis=excluded.allow_analysis,revision=excluded.revision,updated_at=excluded.updated_at WHERE memories.user_id=excluded.user_id''', (memory_id, identity, body.text, stored['recorded_at'] if stored else timestamp, event_date, precision, int(ongoing), int(allowed), stored['revision'] + int(changed) if stored else 1, timestamp))
        result = await owned_memory(identity, memory_id)
        # AI integration point: invalidate dependent analysis when note content/permission changes.
        # Future provider calls belong in the worker, never in this transaction.
        value = memory_value(result)
        value['photos'] = await memory_photos(identity, memory_id)
    # An explicit permission change survives a content conflict, as the wiki requires.
    if conflict is not None:
        raise RequestError(409, 'revision_conflict', 'Note changed. Reload before saving your text.', current_revision=conflict)
    return json_response({'memory': value}, 200 if stored else 201)


async def delete_memory(request):
    identity = await resolve_user(request)
    memory_id = check_id(request.path_params['memory_id'])
    async with db.tx() as connection:
        await owned_memory(identity, memory_id)
        await connection.execute('DELETE FROM memories WHERE id=? AND user_id=?', (memory_id, identity))
    return Response(status_code=204)
