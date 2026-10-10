import sqlite3
from pathlib import Path
from uuid import uuid4

import pytest
import db
from test_foundation import client, credential


def note(text='Invented life note: preparing for exams.', **fields):
    return {'base_revision': 0, 'text': text, **fields}


async def test_notes_create_read_repeat_edit_list_delete(client):
    headers, path = credential(), f'/v1/memories/{uuid4()}'
    created = await client.put(path, headers=headers, json=note())
    assert created.status_code == 201
    first = created.json()['memory']
    assert first['revision'] == 1 and first['event_date'] is None and first['event_precision'] == 'unknown'
    assert (await client.put(path, headers=headers, json=note())).json()['memory'] == first
    assert (await client.get(path, headers=headers)).json()['memory'] == first
    edited = (await client.put(path, headers=headers, json=note('Exam finished.', base_revision=1, event_date='2026-10-08', event_precision='exact', is_ongoing=True))).json()['memory']
    assert edited['revision'] == 2 and edited['recorded_at'] == first['recorded_at']
    assert edited['event_precision'] == 'exact' and edited['is_ongoing']
    assert (await client.get('/v1/memories?ongoing=true', headers=headers)).json()['items'] == [edited]
    assert not (await client.get('/v1/memories?ongoing=false', headers=headers)).json()['items']
    cleared = await client.put(path, headers=headers, json=note('Exam finished.', base_revision=2, event_date=None, event_precision='unknown'))
    assert cleared.status_code == 200 and cleared.json()['memory']['event_date'] is None
    assert (await client.delete(path, headers=headers)).status_code == 204
    assert (await client.get(path, headers=headers)).status_code == 404
    assert (await client.delete(path, headers=headers)).status_code == 404


async def test_notes_owner_collision_conflict_and_permission(client):
    first, second = credential(), credential()
    path = f'/v1/memories/{uuid4()}'
    await client.put(path, headers=first, json=note())
    for method in ('GET', 'PUT', 'DELETE'):
        assert (await client.request(method, path, headers=second, json=note('Overwrite', user_id=first['Authorization'][7:]))).status_code == 404
    assert not (await client.get('/v1/memories', headers=second)).json()['items']
    conflict = await client.put(path, headers=first, json=note('Stale edit', allow_analysis=False))
    assert conflict.status_code == 409 and conflict.json()['current_revision'] == 1
    stored = (await client.get(path, headers=first)).json()['memory']
    assert stored['text'] == note()['text'] and stored['allow_analysis'] is False
    repeat = (await client.put(path, headers=first, json=note())).json()['memory']
    assert repeat['revision'] == 1 and not repeat['allow_analysis']
    assert (await client.put(f'/v1/memories/{uuid4()}', headers=first, json=note(base_revision=1))).status_code == 404


@pytest.mark.parametrize('fields,status', [({'text':'   '},400), ({'text':'x'*2001},413), ({'base_revision':True},400), ({'base_revision':-1},400), ({'event_date':'2026-02-30'},400), ({'event_date':'2026-10-08','event_precision':'unknown'},400), ({'event_precision':'exact'},400), ({'is_ongoing':1},400), ({'allow_analysis':'yes'},400)])
async def test_notes_validation(client, fields, status):
    assert (await client.put(f'/v1/memories/{uuid4()}', headers=credential(), json=note(**fields))).status_code == status


async def test_profile_crud_preserves_settings_and_isolates_users(client):
    first, second = credential(), credential()
    path = '/v1/me/profile'
    assert (await client.get(path, headers=first)).json()['profile']['fields'] == {}
    fields = {'name': ' Sample Person ', 'age': '21', 'favorite_color':'blue'}
    saved = await client.put(path, headers=first, json={'base_revision':0,'fields':fields})
    profile = saved.json()['profile']
    assert saved.status_code == 200 and profile['fields']['name'] == 'Sample Person'
    assert profile['revision'] == 1
    fields['name'] = 'Sample Person'
    assert (await client.put(path, headers=first, json={'base_revision':0,'fields':fields})).json()['profile'] == profile
    assert (await client.get(path, headers=second)).json()['profile']['fields'] == {}
    assert (await client.put(path, headers=first, json={'base_revision':0,'fields':{'name':'Stale'}})).status_code == 409
    await client.put('/v1/me', headers=first, json={'timezone':'America/Detroit','use_history':False})
    assert (await client.get(path, headers=first)).json()['profile'] == profile
    removed = await client.put(path, headers=first, json={'base_revision':1,'fields':{'name':'Sample Person','age':''}})
    assert removed.json()['profile']['fields'] == {'name':'Sample Person'}
    assert (await client.put(path, headers=first, json={'base_revision':2,'fields':{}})).json()['profile']['fields'] == {}
    await client.delete('/v1/me', headers=first)
    assert not await db.rwdb.execute_fetchall('SELECT * FROM profiles')


@pytest.mark.parametrize('fields,status', [({'age':'151'},400), ({'age':'-1'},400), ({'age':'20.5'},400), ({'age':21},400), ({'Name':'Sample'},400), ({'bad key':'Sample'},400), ({'name':'x'*201},413), ({f'field_{i}':'x' for i in range(31)},400)])
async def test_profile_validation(client, fields, status):
    assert (await client.put('/v1/me/profile', headers=credential(), json={'base_revision':0,'fields':fields})).status_code == status


async def test_new_routes_require_bearer(client):
    for method, path in [('GET','/v1/memories'),('GET',f'/v1/memories/{uuid4()}'),('PUT',f'/v1/memories/{uuid4()}'),('DELETE',f'/v1/memories/{uuid4()}'),('GET','/v1/me/profile'),('PUT','/v1/me/profile')]:
        assert (await client.request(method,path,json=note())).status_code == 401


@pytest.mark.parametrize('version', [1, 2])
async def test_additive_upgrade_keeps_existing_records(tmp_path, version):
    path = tmp_path / 'v1.db'
    connection = sqlite3.connect(path)
    schema = Path(db.__file__).with_name('schema.sql').read_text()
    connection.executescript(schema)
    connection.execute('DROP TABLE memory_photos')
    if version == 1:
        connection.execute('DROP TABLE profiles')
    identity = str(uuid4())
    dream_id = str(uuid4())
    connection.execute('INSERT INTO users(id,created_at) VALUES(?,?)', (identity,1))
    connection.execute("INSERT INTO dreams(id,user_id,text,dream_date,source,created_at,updated_at) VALUES(?,?,?,'2026-10-08','text',1,1)", (dream_id,identity,'Kept sample'))
    connection.execute(f'PRAGMA user_version={version}')
    connection.commit()
    connection.close()
    upgraded = await db.open_database(path)
    try:
        assert (await upgraded.execute_fetchall('PRAGMA user_version'))[0][0] == 3
        assert (await upgraded.execute_fetchall('SELECT text FROM dreams WHERE id=?',(dream_id,)))[0][0] == 'Kept sample'
        assert not await upgraded.execute_fetchall('SELECT * FROM profiles')
        assert not await upgraded.execute_fetchall('PRAGMA foreign_key_check')
    finally:
        await upgraded.close()
