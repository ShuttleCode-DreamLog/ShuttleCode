import re

import msgspec
import config
import db
from web import RequestError, json_response, read_body, resolve_user


class ProfileSave(msgspec.Struct):
    base_revision: int
    fields: dict[str, str]


async def profile_value(identity):
    rows = await db.rwdb.execute_fetchall('SELECT * FROM profiles WHERE user_id=?', (identity,))
    return {'fields': msgspec.json.decode(rows[0]['fields_json']) if rows else {}, 'revision': rows[0]['revision'] if rows else 0, 'updated_at': rows[0]['updated_at'] if rows else None}


async def get_profile(request):
    return json_response({'profile': await profile_value(await resolve_user(request))})


async def save_profile(request):
    identity = await resolve_user(request)
    body = await read_body(request, ProfileSave)
    if body.base_revision < 0 or len(body.fields) > 30:
        raise RequestError(400, 'invalid_request', 'Use a nonnegative revision and at most 30 profile fields.')
    fields = {}
    for key, value in body.fields.items():
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,39}', key):
            raise RequestError(400, 'invalid_request', 'Field keys must use lowercase letters, digits and underscores, starting with a letter.')
        value = value.strip()
        if len(value) > 200:
            raise RequestError(413, 'too_large', 'Profile values must be at most 200 characters.')
        if key == 'age' and value and (not re.fullmatch(r'[0-9]{1,3}', value) or not 0 <= int(value) <= 150):
            raise RequestError(400, 'invalid_request', 'Age must be a whole number from 0 to 150.')
        if value:
            fields[key] = value
    async with db.tx() as connection:
        stored = await profile_value(identity)
        if fields != stored['fields']:
            if body.base_revision != stored['revision']:
                raise RequestError(409, 'revision_conflict', 'Profile changed. Reload before saving.', current_revision=stored['revision'])
            await connection.execute('''INSERT INTO profiles(user_id,fields_json,revision,updated_at) VALUES(?,?,?,?)
                ON CONFLICT(user_id) DO UPDATE SET fields_json=excluded.fields_json,revision=excluded.revision,updated_at=excluded.updated_at''', (identity, msgspec.json.encode(fields).decode(), stored['revision'] + 1, config.now()))
        result = await profile_value(identity)
    return json_response({'profile': result})
