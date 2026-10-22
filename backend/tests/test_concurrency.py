import asyncio
from uuid import uuid4

import db
from test_foundation import client, credential


def dream(text, base_revision=0):
    return {'base_revision': base_revision, 'text': text, 'dream_date': '2026-10-21', 'source': 'text', 'permissions': {'analysis': False, 'patterns': False}}


# Many bearer IDs write and read at the same time; the ID alone decides whose rows are touched (wiki 4.2).
async def test_many_users_write_and_read_at_once_without_seeing_each_other(client):
    users = [credential() for _ in range(25)]

    async def keep_journal(headers, n):
        dream_id, note_id = str(uuid4()), str(uuid4())
        for revision in range(3):
            saved = await client.put(f'/v1/dreams/{dream_id}', headers=headers, json=dream(f'Invented dream {n} v{revision + 1}', revision))
            assert saved.status_code == (201 if revision == 0 else 200), saved.text
        assert (await client.put(f'/v1/memories/{note_id}', headers=headers, json={'base_revision': 0, 'text': f'Invented note {n}'})).status_code == 201
        assert (await client.put('/v1/me/profile', headers=headers, json={'base_revision': 0, 'fields': {'name': f'Person {n}'}})).status_code == 200
        return dream_id, note_id

    owned = await asyncio.gather(*(keep_journal(headers, n) for n, headers in enumerate(users)))
    for n, (headers, (dream_id, note_id)) in enumerate(zip(users, owned)):
        items = (await client.get('/v1/dreams', headers=headers)).json()['items']
        assert [(i['id'], i['revision'], i['preview']) for i in items] == [(dream_id, 3, f'Invented dream {n} v3')]
        assert [m['id'] for m in (await client.get('/v1/memories', headers=headers)).json()['items']] == [note_id]
        assert (await client.get('/v1/me/profile', headers=headers)).json()['profile']['fields'] == {'name': f'Person {n}'}
    counts = await db.rwdb.execute_fetchall('SELECT (SELECT count(DISTINCT user_id) FROM dreams), (SELECT count(*) FROM dreams), (SELECT count(*) FROM memories), (SELECT count(*) FROM profiles)')
    assert tuple(counts[0]) == (25, 25, 25, 25)

    # Another user's IDs grant nothing, whatever the method, and a write under them changes nothing.
    first, second = users[0], users[1]
    dream_id, note_id = owned[0]
    for method, path, body in (('GET', f'/v1/dreams/{dream_id}', None), ('PUT', f'/v1/dreams/{dream_id}', dream('Overwrite')), ('DELETE', f'/v1/dreams/{dream_id}', None),
                               ('GET', f'/v1/memories/{note_id}', None), ('DELETE', f'/v1/memories/{note_id}', None)):
        assert (await client.request(method, path, headers=second, json=body)).status_code == 404, (method, path)
    assert (await client.get(f'/v1/dreams/{dream_id}', headers=first)).json()['dream']['text'] == 'Invented dream 0 v3'

    # Two edits of one dream from one stale revision at the same time: exactly one wins, the other is told to reload.
    answers = await asyncio.gather(*(client.put(f'/v1/dreams/{dream_id}', headers=first, json=dream(f'Race {k}', 3)) for k in range(2)))
    assert sorted(a.status_code for a in answers) == [200, 409]
    assert (await client.get(f'/v1/dreams/{dream_id}', headers=first)).json()['dream']['revision'] == 4

    # Half the users leave while the others keep reading; only the leavers' rows go.
    leaving, staying = users[::2], users[1::2]
    await asyncio.gather(*(client.delete('/v1/me', headers=h) for h in leaving), *(client.get('/v1/dreams', headers=h) for h in staying))
    for headers in staying:
        assert len((await client.get('/v1/dreams', headers=headers)).json()['items']) == 1
    remaining = await db.rwdb.execute_fetchall('SELECT count(*) FROM users')
    assert remaining[0][0] == len(staying) and not await db.rwdb.execute_fetchall('PRAGMA foreign_key_check')
