import json
import os
import msgspec
from starlette.responses import Response
import config
import db
import providers
import records
from dreams import check_date, paging
from photos import memory_photos
from web import RequestError, check_id, json_response, read_body, resolve_user


class MemorySave(msgspec.Struct, kw_only=True):
    base_revision: int
    text: str
    title: str | None | msgspec.UnsetType = msgspec.UNSET
    event_date: str | None | msgspec.UnsetType = msgspec.UNSET
    event_precision: str | msgspec.UnsetType = msgspec.UNSET
    is_ongoing: bool | msgspec.UnsetType = msgspec.UNSET
    allow_analysis: bool | msgspec.UnsetType = msgspec.UNSET


def memory_value(row):
    return {**{key: row[key] for key in ('id', 'title', 'text', 'recorded_at', 'event_date', 'event_precision', 'checkin_id', 'revision', 'updated_at')}, 'is_ongoing': bool(row['is_ongoing']), 'allow_analysis': bool(row['allow_analysis'])}


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


class MemorySearch(msgspec.Struct):
    query: str = ''
    ongoing: bool | None = None


def note_text(row):
    return (f"{row['title']}\n{row['text']}" if row['title'] else row['text'])[:config.MAX_EMBED_CHARS]


# Search wording is compared with the notes' vectors like dream search (wiki 4.8.3). Notes with AI use allowed that have no vector
# for their current revision are embedded first, on the first page only so paging keeps one ranking. None means a literal search.
async def similarities(identity, query, offset):
    if not db.vectors or await records.charge(identity, 'text'):
        return None
    model = os.environ['EMBEDDING_MODEL']
    try:
        [vector] = await providers.embed([query], timeout=20)
    except providers.ProviderError:
        return None
    missing = await db.rwdb.execute_fetchall('SELECT m.id,m.title,m.text,m.revision FROM memories m LEFT JOIN memory_vectors mv ON mv.memory_id=m.id AND mv.memory_revision=m.revision AND mv.model=? AND mv.dimensions=? WHERE m.user_id=? AND m.allow_analysis=1 AND mv.memory_id IS NULL ORDER BY m.recorded_at DESC,m.id LIMIT ?',
                                             (model, config.EMBEDDING_DIMENSIONS, identity, config.MAX_SEARCH_EMBEDS)) if offset == 0 else []
    try:
        embedded = await providers.embed([note_text(row) for row in missing], timeout=20) if missing else []
    except providers.ProviderError:
        embedded = []
    if len(embedded) == len(missing):
        async with db.tx() as connection:
            for row, note_vector in zip(missing, embedded):
                # Written only while the note is unchanged and still allowed; a note switched off during the call was already sent.
                await connection.execute('''INSERT INTO memory_vectors(memory_id,user_id,memory_revision,embedding,model,dimensions,updated_at)
                    SELECT id,user_id,revision,vector_as_f32(?),?,?,? FROM memories WHERE id=? AND user_id=? AND revision=? AND allow_analysis=1
                    ON CONFLICT(memory_id) DO UPDATE SET memory_revision=excluded.memory_revision,embedding=excluded.embedding,model=excluded.model,dimensions=excluded.dimensions,updated_at=excluded.updated_at''',
                    (json.dumps(note_vector), model, config.EMBEDDING_DIMENSIONS, config.now(), row['id'], identity, row['revision']))
    rows = await db.rwdb.execute_fetchall("SELECT mv.memory_id,v.distance FROM memory_vectors AS mv JOIN vector_full_scan('memory_vectors','embedding',vector_as_f32(?)) AS v ON mv.rowid=v.rowid JOIN memories m ON m.id=mv.memory_id AND m.revision=mv.memory_revision WHERE mv.user_id=? AND m.allow_analysis=1 AND mv.model=? AND mv.dimensions=?",
                                          (json.dumps(vector), identity, model, config.EMBEDDING_DIMENSIONS))
    return {row['memory_id']: row['distance'] for row in rows}


async def page(request, identity, filters):
    limit, offset = paging(request)
    if len(filters.query) > config.LIMITS['max_message_chars']:
        raise RequestError(413, 'too_large', 'Search text is too long.')
    query = filters.query.strip()
    ranked = await similarities(identity, query, offset) if query else None
    clauses, values = ['user_id=?'], [identity]
    if filters.ongoing is not None:
        clauses.append('is_ongoing=?')
        values.append(int(filters.ongoing))
    if query and ranked is None:
        pattern = '%' + query.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'
        clauses.append("(text LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')")
        values.extend((pattern, pattern))
    order = f"SELECT * FROM memories WHERE {' AND '.join(clauses)} ORDER BY recorded_at DESC,id ASC"
    if ranked is None:
        rows = await db.rwdb.execute_fetchall(f'{order} LIMIT ? OFFSET ?', (*values, limit + 1, offset))
        page_rows, more = rows[:limit], len(rows) > limit
    else:
        # The notes in order of meaning: close enough by vector, or carrying the words literally when no vector can say.
        words = query.lower()
        rows = [row for row in await db.rwdb.execute_fetchall(order, values)
                if ranked.get(row['id'], 2.0) <= config.SEARCH_MAX_DISTANCE or words in row['text'].lower() or words in (row['title'] or '').lower()]
        rows.sort(key=lambda row: ranked.get(row['id'], 1.0))
        page_rows, more = rows[offset:offset + limit], len(rows) > offset + limit
    # Search items carry their similarity like journal search items; null when the note was found by its words.
    items = [{**memory_value(row), 'similarity': round(1 - ranked[row['id']], 3) if ranked and row['id'] in ranked else None} if query else memory_value(row) for row in page_rows]
    photo_rows = await db.rwdb.execute_fetchall(f"SELECT id,memory_id,content_type,length(content) AS byte_count,created_at FROM memory_photos WHERE user_id=? AND memory_id IN ({','.join('?' for _ in items)}) ORDER BY created_at,id", (identity, *(item['id'] for item in items))) if items else []
    by_memory = {}
    for row in photo_rows:
        by_memory.setdefault(row['memory_id'], []).append({key: row[key] for key in ('id','content_type','byte_count','created_at')})
    for item in items:
        item['photos'] = by_memory.get(item['id'], [])
    return json_response({'items': items, 'has_more': more, **({'ranked': ranked is not None} if query else {})})


async def list_memories(request):
    ongoing = request.query_params.get('ongoing')
    if ongoing not in (None, 'true', 'false'):
        raise RequestError(400, 'invalid_request', 'Ongoing must be true or false.')
    return await page(request, await resolve_user(request), MemorySearch(ongoing=None if ongoing is None else ongoing == 'true'))


async def search_memories(request):
    identity = await resolve_user(request)
    return await page(request, identity, await read_body(request, MemorySearch))


async def save_memory(request):
    identity = await resolve_user(request)
    memory_id = check_id(request.path_params['memory_id'])
    body = await read_body(request, MemorySave)
    if body.base_revision < 0 or (body.text and not body.text.strip()):
        raise RequestError(400, 'invalid_request', 'Use a nonnegative revision; text cannot consist only of whitespace.')
    if len(body.text) > config.LIMITS['max_memory_chars']:
        raise RequestError(413, 'too_large', 'Note text is too long.')
    if body.title is not msgspec.UNSET and body.title is not None and len(body.title) > config.LIMITS['max_title_chars']:
        raise RequestError(413, 'too_large', 'Note title is too long.')
    conflict = None
    async with db.tx() as connection:
        rows = await connection.execute_fetchall('SELECT * FROM memories WHERE id=? AND user_id=?', (memory_id, identity))
        stored = rows[0] if rows else None
        if stored is None and body.base_revision > 0:
            raise RequestError(404, 'not_found', 'Note not found.')
        title = (stored['title'] if stored else None) if body.title is msgspec.UNSET else (body.title.strip() or None) if body.title is not None else None
        event_date = (stored['event_date'] if stored else None) if body.event_date is msgspec.UNSET else body.event_date
        precision = (stored['event_precision'] if stored else 'exact' if event_date else 'unknown') if body.event_precision is msgspec.UNSET else body.event_precision
        if event_date is not None:
            check_date(event_date)
        if precision not in ('exact', 'approximate', 'unknown') or (precision == 'unknown') != (event_date is None):
            raise RequestError(400, 'invalid_request', 'Date and precision must agree; use null with unknown for no date.')
        ongoing = stored['is_ongoing'] if stored and body.is_ongoing is msgspec.UNSET else False if body.is_ongoing is msgspec.UNSET else body.is_ongoing
        allowed = stored['allow_analysis'] if stored and body.allow_analysis is msgspec.UNSET else True if body.allow_analysis is msgspec.UNSET else body.allow_analysis
        changed = stored is None or any((body.text != stored['text'], title != stored['title'], event_date != stored['event_date'], precision != stored['event_precision'], ongoing != stored['is_ongoing']))
        if stored and changed and body.base_revision != stored['revision']:
            conflict = stored['revision']
            if allowed != stored['allow_analysis']:
                await connection.execute('UPDATE memories SET allow_analysis=?,updated_at=? WHERE id=? AND user_id=?', (int(allowed), config.now(), memory_id, identity))
        elif changed or allowed != stored['allow_analysis']:
            timestamp = config.now()
            await connection.execute('''INSERT INTO memories(id,user_id,title,text,recorded_at,event_date,event_precision,is_ongoing,allow_analysis,revision,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,text=excluded.text,event_date=excluded.event_date,event_precision=excluded.event_precision,is_ongoing=excluded.is_ongoing,allow_analysis=excluded.allow_analysis,revision=excluded.revision,updated_at=excluded.updated_at WHERE memories.user_id=excluded.user_id''', (memory_id, identity, title, body.text, stored['recorded_at'] if stored else timestamp, event_date, precision, int(ongoing), int(allowed), stored['revision'] + int(changed) if stored else 1, timestamp))
        if stored and changed and conflict is None:
            await records.source_changed(connection, 'memory', memory_id)
        if stored and stored['allow_analysis'] and not allowed:
            await records.source_removed(connection, 'memory', memory_id, False)
            await connection.execute('DELETE FROM memory_vectors WHERE memory_id=? AND user_id=?', (memory_id, identity))
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
        await records.source_removed(connection, 'memory', memory_id, True)
        await connection.execute('DELETE FROM memories WHERE id=? AND user_id=?', (memory_id, identity))
    return Response(status_code=204)
