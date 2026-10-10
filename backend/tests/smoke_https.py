"""Run against the local HTTPS server, with its certificate explicitly trusted."""
import ssl
import sys
import base64
from uuid import uuid4
import httpx

with httpx.Client(base_url='https://127.0.0.1:8443', verify=ssl.create_default_context(cafile='.local/server.crt'), http2=True) as client:
    assert client.get('/v1/me').status_code == 401
    headers = {'Authorization': 'Bearer ' + str(uuid4())}
    response = client.get('/v1/me', headers=headers)
    assert response.status_code == 200
    saved = client.put('/v1/me', headers=headers, json={'timezone': 'America/Detroit', 'reminder_weekday': None, 'use_history': False})
    assert saved.status_code == 200 and saved.json()['use_history'] is False
    path = f'/v1/dreams/{uuid4()}'
    payload = {'base_revision': 0, 'text': 'Invented HTTPS sample: a blue lake.', 'dream_date': '2026-10-08', 'title': 'Lake', 'mood': None, 'source': 'text'}
    created = client.put(path, headers=headers, json=payload)
    assert created.status_code == 201
    assert client.get(path, headers=headers).json()['dream']['text'] == payload['text']
    assert len(client.get('/v1/dreams', headers=headers).json()['items']) == 1
    assert client.delete(path, headers=headers).status_code == 204
    assert client.get(path, headers=headers).status_code == 404
    note_path = f'/v1/memories/{uuid4()}'
    created_note = client.put(note_path, headers=headers, json={'base_revision':0,'text':'Invented life note: building a project.'})
    assert created_note.status_code == 201
    assert client.get(note_path, headers=headers).json()['memory']['revision'] == 1
    assert len(client.get('/v1/memories', headers=headers).json()['items']) == 1
    edited_note = client.put(note_path, headers=headers, json={'base_revision':1,'text':'Invented life note: project completed.'})
    assert edited_note.json()['memory']['revision'] == 2
    photo_path = f'{note_path}/photos/{uuid4()}'
    photo_bytes = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZl8AAAAASUVORK5CYII=')
    photo = client.put(photo_path,headers={**headers,'Content-Type':'image/png'},content=photo_bytes)
    assert photo.status_code == 201
    assert client.get(photo_path,headers=headers).content == photo_bytes
    assert len(client.get(note_path,headers=headers).json()['memory']['photos']) == 1
    assert client.delete(photo_path,headers=headers).status_code == 204
    assert client.delete(note_path, headers=headers).status_code == 204
    assert client.get(note_path, headers=headers).status_code == 404
    profile_path = '/v1/me/profile'
    profile_fields = {'name':'Sample Person','age':'21','favorite_color':'blue'}
    saved_profile = client.put(profile_path, headers=headers, json={'base_revision':0,'fields':profile_fields})
    assert saved_profile.json()['profile']['fields'] == profile_fields
    assert client.get(profile_path, headers=headers).json()['profile']['fields'] == profile_fields
    cleared_profile = client.put(profile_path, headers=headers, json={'base_revision':1,'fields':{}})
    assert cleared_profile.json()['profile']['fields'] == {}
    assert client.delete('/v1/me', headers=headers).status_code == 204
    if '--faults' in sys.argv:
        fault = client.post('/v1/faults', json={'text': 'https-smoke-private-marker', 'where': 'route'})
        assert fault.status_code == 500 and fault.json()['error'] == 'internal'
        assert 'https-smoke-private-marker' not in fault.text
        assert fault.json()['request_id'] == fault.headers['x-request-id']
    print(f'Granian HTTPS smoke passed: identity + Journal/Notes/Profile/photos read/write/delete; protocol={response.http_version}')
