import asyncio
import random
from uuid import uuid4

import pytest
import config
import db
from test_foundation import client, credential

SWITCHES = ('transcription', 'analysis', 'discussion', 'history', 'patterns', 'visuals')


def entry(**fields):
    return {'base_revision': 0, 'text': 'An invented dream by a blue lake.', 'dream_date': '2026-10-08', 'source': 'text', **fields}


async def created(client, headers, **fields):
    dream_id = str(uuid4())
    response = await client.put(f'/v1/dreams/{dream_id}', headers=headers, json=entry(**fields))
    assert response.status_code == 201
    return dream_id


async def stored(dream_id):
    return (await db.rwdb.execute_fetchall('SELECT * FROM dreams WHERE id=?', (dream_id,)))[0]


async def switches(dream_id):
    row = await stored(dream_id)
    return {key: bool(row[f'allow_{key}']) for key in SWITCHES}


async def change(client, headers, dream_id, body):
    return await client.put(f'/v1/dreams/{dream_id}/permissions', headers=headers, json=body)


async def test_partial_change_keeps_other_switches_text_and_revision(client):
    headers = credential()
    dream_id = await created(client, headers)
    before = await stored(dream_id)
    response = await change(client, headers, dream_id, {'analysis': False})
    assert response.status_code == 200
    dream = response.json()['dream']
    assert dream['permissions'] == {**dict.fromkeys(SWITCHES, True), 'analysis': False}
    assert dream['revision'] == 1 and dream['text'] == before['text'] and dream['updated_at'] >= before['updated_at']
    assert await switches(dream_id) == dream['permissions']
    assert (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream'] == dream
    both = (await change(client, headers, dream_id, {'analysis': True, 'history': False})).json()['dream']
    assert both['permissions'] == {**dict.fromkeys(SWITCHES, True), 'history': False}
    assert both['revision'] == 1


async def test_keep_out_turns_all_six_off_and_switches_return_one_at_a_time(client):
    headers = credential()
    dream_id = await created(client, headers)
    off = (await change(client, headers, dream_id, dict.fromkeys(SWITCHES, False))).json()['dream']
    assert off['permissions'] == dict.fromkeys(SWITCHES, False)
    assert await switches(dream_id) == dict.fromkeys(SWITCHES, False)
    one = (await change(client, headers, dream_id, {'visuals': True})).json()['dream']
    assert one['permissions'] == {**dict.fromkeys(SWITCHES, False), 'visuals': True}


async def test_repeat_and_empty_body_change_nothing(client):
    headers = credential()
    dream_id = await created(client, headers)
    first = await change(client, headers, dream_id, {'patterns': False})
    stamp = (await stored(dream_id))['updated_at']
    for body in ({'patterns': False}, {}, {'analysis': True}):
        repeat = await change(client, headers, dream_id, body)
        assert repeat.status_code == 200 and repeat.json() == first.json()
        assert (await stored(dream_id))['updated_at'] == stamp


async def test_creation_permissions_are_kept_until_the_route_changes_them(client):
    headers = credential()
    dream_id = await created(client, headers, permissions={**dict.fromkeys(SWITCHES, True), 'history': False})
    assert (await switches(dream_id))['history'] is False
    assert (await change(client, headers, dream_id, {'history': True})).json()['dream']['permissions']['history'] is True


async def test_text_save_after_change_needs_no_reload_and_keeps_switches(client):
    headers = credential()
    dream_id = await created(client, headers)
    await change(client, headers, dream_id, {'discussion': False})
    edited = await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={**entry(text='Edited invented dream.', permissions=dict.fromkeys(SWITCHES, True)), 'base_revision': 1})
    assert edited.status_code == 200
    dream = edited.json()['dream']
    assert dream['revision'] == 2 and dream['text'] == 'Edited invented dream.'
    assert dream['permissions']['discussion'] is False


async def test_other_users_and_missing_dreams_get_404_without_change(client):
    owner, other = credential(), credential()
    dream_id = await created(client, owner)
    count = len(await db.rwdb.execute_fetchall('SELECT id FROM dreams'))
    for headers, target in ((other, dream_id), (owner, str(uuid4()))):
        response = await change(client, headers, target, {'analysis': False})
        assert response.status_code == 404 and response.json()['error'] == 'not_found'
    stolen = await change(client, other, dream_id, {'analysis': False, 'user_id': owner['Authorization'][7:]})
    assert stolen.status_code == 404
    assert await switches(dream_id) == dict.fromkeys(SWITCHES, True)
    assert len(await db.rwdb.execute_fetchall('SELECT id FROM dreams')) == count


@pytest.mark.parametrize('value', [None, 'Bearer nonsense', 'Bearer 00000000-0000-0000-0000-00000000000A', 'Basic abc'])
async def test_identity_is_required(client, value):
    owner = credential()
    dream_id = await created(client, owner)
    headers = {} if value is None else {'Authorization': value}
    response = await change(client, headers, dream_id, {'analysis': False})
    assert response.status_code == 401 and response.json()['error'] == 'invalid_user'
    assert await switches(dream_id) == dict.fromkeys(SWITCHES, True)


@pytest.mark.parametrize('content', [b'{"analysis": "false"}', b'{"analysis": 0}', b'{"analysis": 1}', b'{"analysis": null}', b'{"analysis": [true]}', b'[]', b'"analysis"', b'{', b''])
async def test_invalid_bodies_are_refused_without_change(client, content):
    headers = credential()
    dream_id = await created(client, headers)
    response = await client.put(f'/v1/dreams/{dream_id}/permissions', headers={**headers, 'Content-Type': 'application/json'}, content=content)
    assert response.status_code == 400 and response.json()['error'] == 'invalid_request'
    assert await switches(dream_id) == dict.fromkeys(SWITCHES, True)


async def test_wrong_type_size_and_id_are_refused(client):
    headers = credential()
    dream_id = await created(client, headers)
    plain = await client.put(f'/v1/dreams/{dream_id}/permissions', headers={**headers, 'Content-Type': 'text/plain'}, content=b'{"analysis": false}')
    assert plain.status_code == 400
    large = await client.put(f'/v1/dreams/{dream_id}/permissions', headers={**headers, 'Content-Type': 'application/json'}, content=b'{"note":"' + b'x' * config.MAX_JSON_BYTES + b'"}')
    assert large.status_code == 413 and large.json()['error'] == 'too_large'
    for target in ('not-a-uuid', dream_id.upper()):
        assert (await change(client, headers, target, {'analysis': False})).status_code == 400
    assert await switches(dream_id) == dict.fromkeys(SWITCHES, True)


async def test_unknown_fields_change_only_switches(client):
    headers = credential()
    dream_id = await created(client, headers)
    response = await change(client, headers, dream_id, {'analysis': False, 'revision': 99, 'text': 'Replaced', 'id': str(uuid4()), 'audio_status': 'uploaded'})
    dream = response.json()['dream']
    assert response.status_code == 200 and dream['permissions']['analysis'] is False
    assert (dream['id'], dream['revision'], dream['text'], dream['audio_status']) == (dream_id, 1, 'An invented dream by a blue lake.', 'none')


@pytest.mark.parametrize('method', ['GET', 'POST', 'DELETE', 'PATCH'])
async def test_other_methods_are_refused_and_keep_the_dream(client, method):
    headers = credential()
    dream_id = await created(client, headers)
    response = await client.request(method, f'/v1/dreams/{dream_id}/permissions', headers=headers, json={'analysis': False})
    assert response.status_code == 405 and response.json()['error'] == 'invalid_request'
    assert (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).status_code == 200
    assert await switches(dream_id) == dict.fromkeys(SWITCHES, True)


async def test_concurrent_changes_to_different_switches_all_apply(client):
    headers = credential()
    dream_id = await created(client, headers)
    for state in (False, True, False):
        responses = await asyncio.gather(*(change(client, headers, dream_id, {key: state}) for key in SWITCHES))
        assert all(response.status_code == 200 for response in responses)
        assert await switches(dream_id) == dict.fromkeys(SWITCHES, state)


async def test_random_sequences_match_a_reference_model(client):
    headers = credential()
    dream_id = await created(client, headers)
    expected = dict.fromkeys(SWITCHES, True)
    generator = random.Random(498)
    for _ in range(300):
        body = {key: generator.random() < 0.5 for key in generator.sample(SWITCHES, generator.randint(0, len(SWITCHES)))}
        expected.update(body)
        response = await change(client, headers, dream_id, body)
        assert response.status_code == 200
        assert response.json()['dream']['permissions'] == expected
        assert await switches(dream_id) == expected
    assert (await stored(dream_id))['revision'] == 1


async def test_list_search_delete_and_user_deletion_still_work(client):
    headers = credential()
    dream_id = await created(client, headers)
    await change(client, headers, dream_id, dict.fromkeys(SWITCHES, False))
    items = (await client.get('/v1/dreams', headers=headers)).json()['items']
    assert [item['id'] for item in items] == [dream_id] and items[0]['revision'] == 1
    found = (await client.post('/v1/dreams/search', headers=headers, json={'query': 'blue lake'})).json()['items']
    assert [item['id'] for item in found] == [dream_id]
    assert (await client.delete(f'/v1/dreams/{dream_id}', headers=headers)).status_code == 204
    assert (await change(client, headers, dream_id, {'analysis': True})).status_code == 404
    second = await created(client, headers)
    await change(client, headers, second, {'visuals': False})
    assert (await client.delete('/v1/me', headers=headers)).status_code == 204
    assert not await db.rwdb.execute_fetchall('SELECT id FROM dreams WHERE id=?', (second,))
