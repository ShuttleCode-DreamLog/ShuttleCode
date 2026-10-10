import re
from datetime import date

import msgspec
from starlette.responses import Response
import config
import db
from web import RequestError, check_id, json_response, read_body, resolve_user

MOODS = {'calm', 'happy', 'excited', 'confused', 'sad', 'anxious', 'afraid', 'angry'}
PERMISSIONS = ('transcription', 'analysis', 'discussion', 'history', 'patterns', 'visuals')


class Permissions(msgspec.Struct):
    transcription: bool = True
    analysis: bool = True
    discussion: bool = True
    history: bool = True
    patterns: bool = True
    visuals: bool = True


class DreamSave(msgspec.Struct, kw_only=True):
    base_revision: int
    text: str
    dream_date: str
    title: str | None | msgspec.UnsetType = msgspec.UNSET
    mood: str | None | msgspec.UnsetType = msgspec.UNSET
    source: str | msgspec.UnsetType = msgspec.UNSET
    permissions: Permissions | None = None


class JournalFilter(msgspec.Struct):
    query: str = ''
    tag: str | None = None
    mood: str | None = None
    from_date: str | None = None
    to_date: str | None = None


def check_date(value):
    try:
        if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
            raise ValueError
        date.fromisoformat(value)
    except ValueError:
        raise RequestError(400, 'invalid_request', 'Date must be a real calendar date in YYYY-MM-DD form.') from None
    return value


def dream_value(row):
    return {**{key: row[key] for key in ('id', 'text', 'revision', 'dream_date', 'title', 'mood', 'source', 'audio_status', 'audio_ms', 'heard_text', 'created_at', 'updated_at')}, 'permissions': {key: bool(row[f'allow_{key}']) for key in PERMISSIONS}, 'tasks': [], 'organization': None}


def journal_item(row):
    return {**{key: row[key] for key in ('id', 'dream_date', 'title', 'mood', 'revision', 'audio_status', 'updated_at')}, 'preview': row['text'][:200], 'summary': None, 'status': 'ready', 'favorite_visual_id': None}


async def owned_dream(identity, dream_id):
    rows = await db.rwdb.execute_fetchall('SELECT * FROM dreams WHERE id=? AND user_id=?', (dream_id, identity))
    if not rows:
        raise RequestError(404, 'not_found', 'Journal entry not found.')
    return rows[0]


async def get_dream(request):
    identity = await resolve_user(request)
    dream_id = check_id(request.path_params['dream_id'])
    return json_response({'dream': dream_value(await owned_dream(identity, dream_id))})


async def save_dream(request):
    identity = await resolve_user(request)
    dream_id = check_id(request.path_params['dream_id'])
    body = await read_body(request, DreamSave)
    check_date(body.dream_date)
    if body.base_revision < 0:
        raise RequestError(400, 'invalid_request', 'Base revision cannot be negative.')
    if body.mood is not msgspec.UNSET and body.mood is not None and body.mood not in MOODS:
        raise RequestError(400, 'invalid_request', 'Mood is not supported.')
    if body.title is not msgspec.UNSET and body.title is not None and len(body.title) > config.LIMITS['max_title_chars']:
        raise RequestError(413, 'too_large', 'Title is too long.')
    async with db.tx() as connection:
        rows = await connection.execute_fetchall('SELECT * FROM dreams WHERE id=? AND user_id=?', (dream_id, identity))
        stored = rows[0] if rows else None
        if stored is None and body.base_revision > 0:
            raise RequestError(404, 'not_found', 'Journal entry not found.')
        source = stored['source'] if stored else body.source
        if source not in ('text', 'voice'):
            raise RequestError(400, 'invalid_request', 'Source is required and must be text or voice.')
        if source == 'text' and not body.text.strip():
            raise RequestError(400, 'invalid_request', 'Write some text before saving.')
        if len(body.text) > config.LIMITS['max_dream_chars'] and (stored is None or len(body.text) > len(stored['text'])):
            raise RequestError(413, 'too_large', 'Journal text is too long.')
        title = (stored['title'] if stored else None) if body.title is msgspec.UNSET else (body.title.strip() or None) if body.title is not None else None
        mood = (stored['mood'] if stored else None) if body.mood is msgspec.UNSET else body.mood
        text_changed = stored is not None and body.text != stored['text']
        if text_changed and body.base_revision != stored['revision']:
            raise RequestError(409, 'revision_conflict', 'This entry changed. Reload it before saving your text.', current_revision=stored['revision'])
        unchanged = stored is not None and all((body.text == stored['text'], title == stored['title'], mood == stored['mood'], body.dream_date == stored['dream_date']))
        if not unchanged:
            revision = stored['revision'] + int(text_changed) if stored else 1
            timestamp = config.now()
            permissions = body.permissions or Permissions()
            values = tuple(stored[f'allow_{key}'] if stored else int(getattr(permissions, key)) for key in PERMISSIONS)
            await connection.execute('''INSERT INTO dreams(id,user_id,text,revision,dream_date,title,mood,source,audio_status,allow_transcription,allow_analysis,allow_discussion,allow_history,allow_patterns,allow_visuals,created_at,updated_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET text=excluded.text,revision=excluded.revision,dream_date=excluded.dream_date,title=excluded.title,mood=excluded.mood,updated_at=excluded.updated_at
                WHERE dreams.user_id=excluded.user_id''', (dream_id, identity, body.text, revision, body.dream_date, title, mood, source, stored['audio_status'] if stored else 'expected' if source == 'voice' else 'none', *values, stored['created_at'] if stored else timestamp, timestamp))
        result = await owned_dream(identity, dream_id)
        # AI integration point: enqueue revision-keyed dream processing here in this transaction.
        # This is where the future worker will call the provider API after commit, with owner/permission checks.
    return json_response({'dream': dream_value(result)}, 200 if stored else 201)


def paging(request):
    try:
        limit = int(request.query_params.get('limit', '50'))
        offset = int(request.query_params.get('offset', '0'))
    except ValueError:
        raise RequestError(400, 'invalid_request', 'Paging values must be integers.') from None
    if not 1 <= limit <= 200 or offset < 0:
        raise RequestError(400, 'invalid_request', 'Limit must be 1 through 200 and offset cannot be negative.')
    return limit, offset


async def page(request, identity, filters):
    limit, offset = paging(request)
    clauses, values = ['d.user_id=?'], [identity]
    if len(filters.query) > config.LIMITS['max_message_chars']:
        raise RequestError(413, 'too_large', 'Search text is too long.')
    if filters.query:
        pattern = '%' + filters.query.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'
        clauses.append("(d.text LIKE ? ESCAPE '\\' OR d.title LIKE ? ESCAPE '\\')")
        values.extend((pattern, pattern))
    if filters.mood is not None:
        if filters.mood not in MOODS:
            raise RequestError(400, 'invalid_request', 'Mood is not supported.')
        clauses.append('d.mood=?')
        values.append(filters.mood)
    for field, comparison in ((filters.from_date, '>='), (filters.to_date, '<=')):
        if field is not None:
            check_date(field)
            clauses.append(f'd.dream_date{comparison}?')
            values.append(field)
    if filters.from_date and filters.to_date and filters.from_date > filters.to_date:
        raise RequestError(400, 'invalid_request', 'Start date must not be after end date.')
    if filters.tag is not None:
        clauses.append("EXISTS(SELECT 1 FROM effective_tags t WHERE t.dream_id=d.id AND t.user_id=d.user_id AND t.text=? AND t.output_status='current')")
        values.append(' '.join(filters.tag.lower().split()))
    rows = await db.rwdb.execute_fetchall(f"SELECT d.* FROM dreams d WHERE {' AND '.join(clauses)} ORDER BY d.dream_date DESC,d.created_at DESC,d.id ASC LIMIT ? OFFSET ?", (*values, limit + 1, offset))
    return json_response({'items': [journal_item(row) for row in rows[:limit]], 'has_more': len(rows) > limit})


async def list_dreams(request):
    return await page(request, await resolve_user(request), JournalFilter())


async def search_dreams(request):
    identity = await resolve_user(request)
    return await page(request, identity, await read_body(request, JournalFilter))


async def delete_dream(request):
    identity = await resolve_user(request)
    dream_id = check_id(request.path_params['dream_id'])
    async with db.tx() as connection:
        await owned_dream(identity, dream_id)
        await connection.execute('DELETE FROM dreams WHERE id=? AND user_id=?', (dream_id, identity))
    for path in (request.app.state.data_dir / 'audio').glob(f'{dream_id}.*'):
        path.unlink(missing_ok=True)
    return Response(status_code=204)
