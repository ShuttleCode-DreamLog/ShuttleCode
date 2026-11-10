from uuid import uuid4

import msgspec
from starlette.responses import Response
import config
import db
from web import RequestError, check_id, json_response, read_body, resolve_user

COLORS = ('sage', 'blue', 'rose', 'amber', 'violet', 'teal')


class TagBody(msgspec.Struct):
    text: str


class SelectionBody(msgspec.Struct):
    tag_ids: list[str]


def label(text):
    text = ' '.join(text.split())
    if not text:
        raise RequestError(400, 'invalid_request', 'Write a tag name.')
    if len(text) > config.LIMITS['max_tag_chars']:
        raise RequestError(413, 'too_large', 'Tag is too long.')
    return text, text.casefold()


def value(row):
    return {key: row[key] for key in ('id', 'text', 'color')}


async def import_existing(connection, identity):
    # Remember each source even after library deletion, so opening the picker never resurrects it.
    rows = await connection.execute_fetchall("SELECT e.* FROM effective_tags e LEFT JOIN imported_tag_links l ON l.source_id=e.tag_id WHERE e.user_id=? AND e.output_status='current' AND (l.source_id IS NULL OR l.source_text<>e.text) ORDER BY e.position", (identity,))
    for row in rows:
        text, key = label(row['text'])
        existing = await connection.execute_fetchall('SELECT id FROM user_tags WHERE user_id=? AND label_key=?', (identity, key))
        tag_id = existing[0]['id'] if existing else str(uuid4())
        if not existing:
            color = COLORS[int(tag_id.replace('-', '')[:8], 16) % len(COLORS)]
            await connection.execute('INSERT INTO user_tags(id,user_id,text,label_key,color,created_at) VALUES(?,?,?,?,?,?)', (tag_id, identity, text, key, color, config.now()))
        await connection.execute('INSERT INTO imported_tag_links(source_id,user_id,tag_id,source_text) VALUES(?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET tag_id=excluded.tag_id,source_text=excluded.source_text',
                                 (row['tag_id'], identity, tag_id, row['text']))


async def library(connection, identity):
    return {'tags': [value(row) for row in await connection.execute_fetchall('SELECT * FROM user_tags WHERE user_id=? ORDER BY created_at,id', (identity,))]}


async def dream_tags(connection, identity, dream_id):
    rows = await connection.execute_fetchall('SELECT t.* FROM user_tags t JOIN visible_user_tags d ON d.tag_id=t.id WHERE t.user_id=? AND d.user_id=? AND d.dream_id=? GROUP BY t.id ORDER BY min(d.position),t.id', (identity, identity, dream_id))
    return [value(row) for row in rows]


async def set_dream_tags(connection, identity, dream_id, ids):
    ids = list(dict.fromkeys(check_id(tag_id) for tag_id in ids))
    if len(ids) > 50:
        raise RequestError(400, 'invalid_request', 'Choose at most 50 tags per dream.')
    for tag_id in ids:
        if not await connection.execute_fetchall('SELECT 1 FROM user_tags WHERE id=? AND user_id=?', (tag_id, identity)):
            raise RequestError(404, 'not_found', 'A selected tag is no longer available. Open Add tag to update your selection.')
    await connection.execute('UPDATE imported_tag_links SET selected=0 WHERE user_id=? AND source_id IN (SELECT id FROM tags WHERE dream_id=?)', (identity, dream_id))
    await connection.execute('DELETE FROM dream_user_tags WHERE dream_id=? AND user_id=?', (dream_id, identity))
    await connection.executemany('INSERT INTO dream_user_tags(dream_id,tag_id,user_id) VALUES(?,?,?)', [(dream_id, tag_id, identity) for tag_id in ids])


async def list_library(request):
    identity = await resolve_user(request)
    async with db.tx() as connection:
        await import_existing(connection, identity)
        result = await library(connection, identity)
    return json_response(result)


async def create_tag(request):
    identity = await resolve_user(request)
    text, key = label((await read_body(request, TagBody)).text)
    async with db.tx() as connection:
        await import_existing(connection, identity)
        rows = await connection.execute_fetchall('SELECT * FROM user_tags WHERE user_id=? AND label_key=?', (identity, key))
        if rows:
            return json_response({'tag': value(rows[0])})
        tag_id = str(uuid4())
        color = COLORS[int(tag_id.replace('-', '')[:8], 16) % len(COLORS)]
        await connection.execute('INSERT INTO user_tags(id,user_id,text,label_key,color,created_at) VALUES(?,?,?,?,?,?)', (tag_id, identity, text, key, color, config.now()))
    return json_response({'tag': {'id': tag_id, 'text': text, 'color': color}}, 201)


async def rename_tag(request):
    identity = await resolve_user(request)
    tag_id = check_id(request.path_params['tag_id'])
    text, key = label((await read_body(request, TagBody)).text)
    async with db.tx() as connection:
        await import_existing(connection, identity)
        if not await connection.execute_fetchall('SELECT 1 FROM user_tags WHERE id=? AND user_id=?', (tag_id, identity)):
            raise RequestError(404, 'not_found', 'Tag not found.')
        if await connection.execute_fetchall('SELECT 1 FROM user_tags WHERE user_id=? AND label_key=? AND id<>?', (identity, key, tag_id)):
            raise RequestError(409, 'duplicate_tag', 'A tag with this name already exists.')
        await connection.execute('UPDATE user_tags SET text=?,label_key=? WHERE id=? AND user_id=?', (text, key, tag_id, identity))
        result = await library(connection, identity)
    return json_response(result)


async def delete_tag(request):
    identity = await resolve_user(request)
    tag_id = check_id(request.path_params['tag_id'])
    async with db.tx() as connection:
        await import_existing(connection, identity)
        await connection.execute('DELETE FROM user_tags WHERE id=? AND user_id=?', (tag_id, identity))
    return Response(status_code=204)


async def save_selection(request):
    from dreams import owned_dream, dream_body
    identity = await resolve_user(request)
    dream_id = check_id(request.path_params['dream_id'])
    body = await read_body(request, SelectionBody)
    async with db.tx() as connection:
        await import_existing(connection, identity)
        dream = await owned_dream(identity, dream_id)
        await set_dream_tags(connection, identity, dream_id, body.tag_ids)
        result = await dream_body(dream)
    return json_response({'dream': result})
