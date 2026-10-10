import base64
from uuid import uuid4

import pytest
import config
import db
from test_foundation import client, credential

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZl8AAAAASUVORK5CYII=')


async def photo_note(client, headers):
    path = f'/v1/memories/{uuid4()}'
    assert (await client.put(path, headers=headers, json={'base_revision':0,'text':'Invented photo note.'})).status_code == 201
    return path


async def test_photo_upload_repeat_read_list_remove_and_note_cascade(client):
    headers = credential()
    note = await photo_note(client, headers)
    path = f'{note}/photos/{uuid4()}'
    upload_headers = {**headers,'Content-Type':'image/png'}
    saved = await client.put(path, headers=upload_headers, content=PNG)
    assert saved.status_code == 201
    photo = saved.json()['photo']
    repeated = await client.put(path, headers=upload_headers, content=PNG)
    assert repeated.status_code == 200 and repeated.json()['photo'] == photo
    read = await client.get(path, headers=headers)
    assert read.content == PNG and read.headers['content-type'] == 'image/png'
    assert read.headers['cache-control'] == 'no-store'
    assert (await client.get(note, headers=headers)).json()['memory']['photos'] == [photo]
    assert (await client.get('/v1/memories', headers=headers)).json()['items'][0]['photos'] == [photo]
    assert (await client.delete(path, headers=headers)).status_code == 204
    assert (await client.get(path, headers=headers)).status_code == 404
    assert (await client.delete(path, headers=headers)).status_code == 404
    await client.put(path, headers=upload_headers, content=PNG)
    await client.delete(note, headers=headers)
    assert not await db.rwdb.execute_fetchall('SELECT * FROM memory_photos')


async def test_photo_ownership_cross_note_collision_and_user_cascade(client):
    first, second = credential(), credential()
    note = await photo_note(client, first)
    other_note = await photo_note(client, second)
    photo_id = str(uuid4())
    path = f'{note}/photos/{photo_id}'
    await client.put(path, headers={**first,'Content-Type':'image/png'}, content=PNG)
    for method in ('GET','PUT','DELETE'):
        assert (await client.request(method,path,headers={**second,'Content-Type':'image/png'},content=PNG)).status_code == 404
    assert (await client.put(f'{other_note}/photos/{photo_id}',headers={**second,'Content-Type':'image/png'},content=PNG)).status_code == 404
    assert (await client.get(path,headers=first)).content == PNG
    await client.delete('/v1/me',headers=first)
    assert not await db.rwdb.execute_fetchall('SELECT * FROM memory_photos')


async def test_photo_validation_count_size_and_auth(client, monkeypatch):
    headers = credential()
    note = await photo_note(client,headers)
    path = f'{note}/photos/{uuid4()}'
    assert (await client.put(path,headers={'Content-Type':'image/png'},content=PNG)).status_code == 401
    assert (await client.put(path,headers={**headers,'Content-Type':'application/octet-stream'},content=PNG)).status_code == 400
    assert (await client.put(path,headers={**headers,'Content-Type':'image/png'},content=b'bad')).status_code == 400
    assert (await client.put(path,headers={**headers,'Content-Type':'image/jpeg'},content=PNG)).status_code == 400
    monkeypatch.setattr(config,'MAX_PHOTO_BYTES',10)
    assert (await client.put(path,headers={**headers,'Content-Type':'image/png'},content=PNG)).status_code == 413
    monkeypatch.setattr(config,'MAX_PHOTO_BYTES',5000000)
    for _ in range(5):
        assert (await client.put(f'{note}/photos/{uuid4()}',headers={**headers,'Content-Type':'image/png'},content=PNG)).status_code == 201
    assert (await client.put(path,headers={**headers,'Content-Type':'image/png'},content=PNG)).status_code == 413


async def test_photo_only_note(client):
    headers = credential()
    note = f'/v1/memories/{uuid4()}'
    created = await client.put(note,headers=headers,json={'base_revision':0,'text':''})
    assert created.status_code == 201
    photo = f'{note}/photos/{uuid4()}'
    assert (await client.put(photo,headers={**headers,'Content-Type':'image/png'},content=PNG)).status_code == 201
    stored = (await client.get(note,headers=headers)).json()['memory']
    assert stored['text'] == '' and len(stored['photos']) == 1
