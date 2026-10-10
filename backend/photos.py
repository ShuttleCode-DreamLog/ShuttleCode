from starlette.responses import Response
import config
import db
from web import RequestError, check_id, json_response, resolve_user


def photo_value(row):
    return {key: row[key] for key in ('id', 'content_type', 'byte_count', 'created_at')}


async def memory_photos(identity, memory_id):
    rows = await db.rwdb.execute_fetchall('SELECT id,content_type,length(content) AS byte_count,created_at FROM memory_photos WHERE user_id=? AND memory_id=? ORDER BY created_at,id', (identity, memory_id))
    return [photo_value(row) for row in rows]


async def get_photo(request):
    identity = await resolve_user(request)
    memory_id, photo_id = [check_id(request.path_params[key]) for key in ('memory_id', 'photo_id')]
    rows = await db.rwdb.execute_fetchall('SELECT content,content_type FROM memory_photos WHERE user_id=? AND memory_id=? AND id=?', (identity, memory_id, photo_id))
    if not rows:
        raise RequestError(404, 'not_found', 'Photo not found.')
    return Response(rows[0]['content'], media_type=rows[0]['content_type'], headers={'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'})


async def save_photo(request):
    identity = await resolve_user(request)
    memory_id, photo_id = [check_id(request.path_params[key]) for key in ('memory_id', 'photo_id')]
    content_type = request.headers.get('content-type', '').split(';')[0].lower()
    if content_type not in ('image/jpeg', 'image/png'):
        raise RequestError(400, 'invalid_request', 'Upload JPEG or PNG image bytes.')
    content = bytearray()
    async for chunk in request.stream():
        content.extend(chunk)
        if len(content) > config.MAX_PHOTO_BYTES:
            raise RequestError(413, 'too_large', 'Photo must be at most 5 MB.')
    valid = content.startswith(b'\xff\xd8\xff') and content.endswith(b'\xff\xd9') if content_type == 'image/jpeg' else content.startswith(b'\x89PNG\r\n\x1a\n') and b'IEND' in content[-12:]
    if not valid:
        raise RequestError(400, 'invalid_request', 'Image bytes do not match the declared format.')
    async with db.tx() as connection:
        if not await connection.execute_fetchall('SELECT 1 FROM memories WHERE user_id=? AND id=?', (identity, memory_id)):
            raise RequestError(404, 'not_found', 'Note not found.')
        existing = await connection.execute_fetchall('SELECT user_id,memory_id FROM memory_photos WHERE id=?', (photo_id,))
        if existing and (existing[0]['user_id'] != identity or existing[0]['memory_id'] != memory_id):
            raise RequestError(404, 'not_found', 'Photo not found.')
        count = (await connection.execute_fetchall('SELECT count(*) FROM memory_photos WHERE user_id=? AND memory_id=?', (identity, memory_id)))[0][0]
        if not existing and count >= config.MAX_NOTE_PHOTOS:
            raise RequestError(413, 'too_large', 'A note can hold at most 5 photos.')
        await connection.execute('''INSERT INTO memory_photos(id,user_id,memory_id,content_type,content,created_at) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET content_type=excluded.content_type,content=excluded.content
            WHERE memory_photos.user_id=excluded.user_id AND memory_photos.memory_id=excluded.memory_id''', (photo_id, identity, memory_id, content_type, bytes(content), config.now()))
        photos = await memory_photos(identity, memory_id)
    return json_response({'photo': next(photo for photo in photos if photo['id'] == photo_id)}, 200 if existing else 201)


async def delete_photo(request):
    identity = await resolve_user(request)
    memory_id, photo_id = [check_id(request.path_params[key]) for key in ('memory_id', 'photo_id')]
    async with db.tx() as connection:
        if not await connection.execute_fetchall('SELECT 1 FROM memory_photos WHERE user_id=? AND memory_id=? AND id=?', (identity, memory_id, photo_id)):
            raise RequestError(404, 'not_found', 'Photo not found.')
        await connection.execute('DELETE FROM memory_photos WHERE user_id=? AND memory_id=? AND id=?', (identity, memory_id, photo_id))
    return Response(status_code=204)
