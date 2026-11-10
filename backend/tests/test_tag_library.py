from uuid import uuid4

import pytest
import db
from test_foundation import client, credential
from test_journal import entry


async def save(client, headers, dream_id, **fields):
    return await client.put(f'/v1/dreams/{dream_id}', headers=headers, json=entry(**fields))


async def tag(client, headers, text):
    response = await client.post('/v1/tag-library', headers=headers, json={'text': text})
    assert response.status_code in (200, 201)
    return response.json()['tag']


async def test_library_normalizes_deduplicates_and_is_owned(client):
    owner, other = credential(), credential()
    first = await tag(client, owner, '  Blue   sky ')
    assert first['text'] == 'Blue sky' and first['color']
    assert (await tag(client, owner, 'blue SKY'))['id'] == first['id']
    another = await tag(client, other, 'Blue sky')
    assert another['id'] != first['id']
    assert (await client.get('/v1/tag-library', headers=owner)).json()['tags'] == [first]
    assert (await client.put('/v1/tag-library/' + first['id'], headers=other, json={'text': 'Stolen'})).status_code == 404
    assert (await client.delete('/v1/tag-library/' + first['id'], headers=other)).status_code == 204
    assert (await client.get('/v1/tag-library', headers=owner)).json()['tags'] == [first]
    second = await tag(client, owner, 'Ocean')
    assert (await client.put('/v1/tag-library/' + second['id'], headers=owner, json={'text': 'BLUE SKY'})).status_code == 409


@pytest.mark.parametrize('text,status', [('', 400), ('  \n ', 400), ('a' * 61, 413), (42, 400)])
async def test_invalid_library_names(client, text, status):
    assert (await client.post('/v1/tag-library', headers=credential(), json={'text': text})).status_code == status


async def test_manual_tags_attach_filter_rename_remove_without_ai_work(client):
    headers = credential()
    dream_id = str(uuid4())
    created = await save(client, headers, dream_id)
    original = created.json()['dream']
    first = await tag(client, headers, 'Blue Sky')
    second = await tag(client, headers, 'Home')
    tasks_before = [dict(row) for row in await db.rwdb.execute_fetchall('SELECT * FROM tasks')]
    response = await client.put(f'/v1/dreams/{dream_id}/tags', headers=headers, json={'tag_ids': [first['id'], second['id'], first['id']]})
    assert response.status_code == 200
    assert {t['id'] for t in response.json()['dream']['custom_tags']} == {first['id'], second['id']}
    assert response.json()['dream']['text'] == original['text']
    assert response.json()['dream']['revision'] == original['revision']
    assert [dict(row) for row in await db.rwdb.execute_fetchall('SELECT * FROM tasks')] == tasks_before
    listing = (await client.post('/v1/dreams/search', headers=headers, json={'tag': 'blue sky'})).json()
    assert [d['id'] for d in listing['items']] == [dream_id]
    assert {'category': 'custom', 'text': 'Blue Sky'} in listing['items'][0]['tags']
    assert (await client.put('/v1/tag-library/' + first['id'], headers=headers, json={'text': 'Sunrise'})).status_code == 200
    assert (await client.post('/v1/dreams/search', headers=headers, json={'tag': 'blue sky'})).json()['items'] == []
    assert (await client.post('/v1/dreams/search', headers=headers, json={'tag': 'SUNRISE'})).json()['items'][0]['id'] == dream_id
    assert (await client.delete('/v1/tag-library/' + first['id'], headers=headers)).status_code == 204
    assert (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream']['custom_tags'] == [second]
    assert (await client.put(f'/v1/dreams/{dream_id}/tags', headers=headers, json={'tag_ids': []})).json()['dream']['custom_tags'] == []


async def test_dream_creation_with_tags_is_atomic_and_legacy_saves_preserve_selection(client):
    owner, other = credential(), credential()
    first = await tag(client, owner, 'Train')
    foreign = await tag(client, other, 'Private')
    dream_id = str(uuid4())
    invalid = await save(client, owner, dream_id, tag_ids=[foreign['id']])
    assert invalid.status_code == 404
    assert (await client.get(f'/v1/dreams/{dream_id}', headers=owner)).status_code == 404
    response = await save(client, owner, dream_id, tag_ids=[first['id']])
    assert response.status_code == 201 and response.json()['dream']['custom_tags'] == [first]
    assert (await save(client, owner, dream_id, base_revision=1)).json()['dream']['custom_tags'] == [first]
    assert (await client.put(f'/v1/dreams/{dream_id}/tags', headers=other, json={'tag_ids': []})).status_code == 404
    assert (await client.put(f'/v1/dreams/{dream_id}/tags', headers=owner, json={'tag_ids': [foreign['id']]})).status_code == 404
    assert (await client.get(f'/v1/dreams/{dream_id}', headers=owner)).json()['dream']['custom_tags'] == [first]
    assert (await client.delete('/v1/me', headers=owner)).status_code == 204
    assert not await db.rwdb.execute_fetchall('SELECT * FROM dream_user_tags')
    assert len(await db.rwdb.execute_fetchall('SELECT * FROM user_tags')) == 1


async def test_existing_dream_tags_share_library_selection_and_do_not_resurrect(client):
    from test_analysis import organized
    headers, other = credential(), credential()
    user = headers['Authorization'][7:]
    first, second, foreign = str(uuid4()), str(uuid4()), str(uuid4())
    await save(client, headers, first)
    await save(client, headers, second)
    await save(client, other, foreign)
    existing = await tag(client, headers, 'Lake')
    await organized(user, first, tags=(('place', 'lake', 'lake'),))
    await organized(user, second, tags=(('place', 'lake', 'lake'),))
    await organized(other['Authorization'][7:], foreign, tags=(('place', 'private forest', 'forest'),))
    before = [dict(row) for row in await db.rwdb.execute_fetchall('SELECT * FROM tasks')]
    library = (await client.get('/v1/tag-library', headers=headers)).json()['tags']
    assert library == [existing]
    detail = (await client.get(f'/v1/dreams/{first}', headers=headers)).json()['dream']
    assert detail['custom_tags'] == [existing]
    assert (await client.get('/v1/dreams', headers=headers)).json()['items'][0]['tags'] == [{'category': 'place', 'text': 'Lake'}]
    assert [dict(row) for row in await db.rwdb.execute_fetchall('SELECT * FROM tasks')] == before
    assert (await client.put('/v1/tag-library/' + existing['id'], headers=headers, json={'text': 'Water'})).status_code == 200
    for dream_id in [first, second]:
        dream = (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream']
        assert dream['custom_tags'][0]['text'] == 'Water'
        assert dream['organization']['tags'][0]['text'] == 'lake'
    assert (await client.put(f'/v1/dreams/{first}/tags', headers=headers, json={'tag_ids': []})).status_code == 200
    assert (await client.get(f'/v1/dreams/{first}', headers=headers)).json()['dream']['custom_tags'] == []
    found = (await client.post('/v1/dreams/search', headers=headers, json={'tags': ['Water']})).json()['items']
    assert [row['id'] for row in found] == [second]
    assert (await client.delete('/v1/tag-library/' + existing['id'], headers=headers)).status_code == 204
    assert (await client.get('/v1/tag-library', headers=headers)).json()['tags'] == []
    assert all(row['tags'] == [] for row in (await client.get('/v1/dreams', headers=headers)).json()['items'])
    assert (await client.get(f'/v1/dreams/{second}', headers=headers)).json()['dream']['custom_tags'] == []
