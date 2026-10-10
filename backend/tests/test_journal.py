from uuid import uuid4

import pytest
import config
import db
from test_foundation import client, credential


def entry(text='An invented dream by a blue lake.', **fields):
    return {'base_revision': 0, 'text': text, 'dream_date': '2026-10-08', 'source': 'text', **fields}


async def test_create_read_repeat_edit_and_delete(client):
    headers, identity = credential(), str(uuid4())
    path = f'/v1/dreams/{identity}'
    first = await client.put(path, headers=headers, json=entry(title='Lake'))
    assert first.status_code == 201
    assert first.json()['dream']['revision'] == 1
    assert first.json()['dream']['tasks'] == []
    repeat = await client.put(path, headers=headers, json=entry(title='Lake'))
    assert repeat.status_code == 200 and repeat.json() == first.json()
    read = await client.get(path, headers=headers)
    assert read.json() == first.json()
    page = (await client.get('/v1/dreams', headers=headers)).json()
    assert [item['id'] for item in page['items']] == [identity]
    assert page['items'][0]['preview'] == entry()['text']
    changed = await client.put(path, headers=headers, json=entry('Another invented dream.', base_revision=1))
    assert changed.status_code == 200 and changed.json()['dream']['revision'] == 2
    assert changed.json()['dream']['title'] == 'Lake'
    assert (await client.delete(path, headers=headers)).status_code == 204
    assert (await client.get(path, headers=headers)).status_code == 404
    assert (await client.delete(path, headers=headers)).status_code == 404
    assert (await client.get('/v1/dreams', headers=headers)).json()['items'] == []


async def test_owner_body_never_grants_access_and_collision_never_overwrites(client):
    first, second = credential(), credential()
    path = f'/v1/dreams/{uuid4()}'
    await client.put(path, headers=first, json=entry())
    for method in ('GET', 'PUT', 'DELETE'):
        response = await client.request(method, path, headers=second, json=entry('Overwrite', user_id=first['Authorization'][7:]))
        assert response.status_code == 404
    assert (await client.get('/v1/dreams', headers=second)).json()['items'] == []
    assert (await client.get(path, headers=first)).json()['dream']['text'] == entry()['text']
    assert (await client.put(f'/v1/dreams/{uuid4()}', headers=first, json=entry(base_revision=1))).status_code == 404


async def test_conflict_preserves_every_field_and_metadata_keeps_revision(client):
    headers, path = credential(), f'/v1/dreams/{uuid4()}'
    await client.put(path, headers=headers, json=entry(title='Original', mood='calm'))
    conflict = await client.put(path, headers=headers, json=entry('Different', title='Changed'))
    assert conflict.status_code == 409 and conflict.json()['current_revision'] == 1
    dream = (await client.get(path, headers=headers)).json()['dream']
    assert dream['title'] == 'Original' and dream['text'] == entry()['text']
    metadata = await client.put(path, headers=headers, json=entry(title=None, mood=None, dream_date='2030-01-01'))
    assert metadata.status_code == 200
    dream = metadata.json()['dream']
    assert dream['revision'] == 1 and dream['title'] is None and dream['mood'] is None


@pytest.mark.parametrize('fields,status', [({'text': '   '},400), ({'dream_date':'2026-02-30'},400), ({'dream_date':'20261008'},400), ({'mood':'unsupported'},400), ({'base_revision':-1},400), ({'base_revision':True},400), ({'title':'x'*121},413), ({'text':'x'*20001},413)])
async def test_invalid_input(client, fields, status):
    assert (await client.put(f'/v1/dreams/{uuid4()}', headers=credential(), json=entry(**fields))).status_code == status


async def test_empty_title_permissions_and_source_are_stable(client):
    headers, path = credential(), f'/v1/dreams/{uuid4()}'
    created = await client.put(path, headers=headers, json=entry(title='  ', permissions={'history': False}))
    dream = created.json()['dream']
    assert dream['title'] is None and dream['permissions']['history'] is False
    updated = await client.put(path, headers=headers, json=entry(source='voice', permissions={'history':True}))
    assert updated.json()['dream']['source'] == 'text'
    assert updated.json()['dream']['permissions']['history'] is False
    assert (await client.put(f'/v1/dreams/{uuid4()}', headers=headers, json=entry(permissions=None))).status_code == 201


async def test_paging_is_stable_and_search_escapes_wildcards(client, monkeypatch):
    headers = credential()
    monkeypatch.setattr(config, 'now', lambda: 1234)
    identities = []
    for index in range(60):
        identity = str(uuid4())
        identities.append(identity)
        text = '100% lake' if index == 0 else 'under_score' if index == 1 else f'invented dream {index}'
        assert (await client.put(f'/v1/dreams/{identity}', headers=headers, json=entry(text))).status_code == 201
    first = (await client.get('/v1/dreams', headers=headers)).json()
    second = (await client.get('/v1/dreams?offset=50', headers=headers)).json()
    assert first['has_more'] and not second['has_more']
    assert [item['id'] for item in first['items'] + second['items']] == sorted(identities)
    for query, expected in [('%',1), ('_',1), ('',50), ('INVENTED',50)]:
        found = await client.post('/v1/dreams/search', headers=headers, json={'query':query})
        assert found.status_code == 200 and len(found.json()['items']) == expected
    for suffix in ('?limit=0','?limit=201','?offset=-1','?limit=oops'):
        assert (await client.get('/v1/dreams'+suffix, headers=headers)).status_code == 400
    assert (await client.post('/v1/dreams/search', headers=headers, json={'from_date':'2026-10-09','to_date':'2026-10-08'})).status_code == 400


async def test_shorten_preexisting_over_limit_text(client):
    headers, identity = credential(), str(uuid4())
    path = f'/v1/dreams/{identity}'
    await client.put(path, headers=headers, json=entry())
    async with db.tx() as connection:
        await connection.execute('UPDATE dreams SET text=? WHERE id=?', ('x'*21000, identity))
    assert (await client.put(path, headers=headers, json=entry('y'*20500,base_revision=1))).status_code == 200
    assert (await client.put(path, headers=headers, json=entry('z'*20501,base_revision=2))).status_code == 413


async def test_missing_credentials_and_invalid_path_id(client):
    for method, path in [('GET','/v1/dreams'),('POST','/v1/dreams/search'),('GET',f'/v1/dreams/{uuid4()}'),('PUT',f'/v1/dreams/{uuid4()}'),('DELETE',f'/v1/dreams/{uuid4()}')]:
        assert (await client.request(method,path,json=entry())).status_code == 401
    assert (await client.get('/v1/dreams/not-a-uuid',headers=credential())).status_code == 400
