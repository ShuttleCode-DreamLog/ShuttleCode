import json
from uuid import uuid4

import db
import records
from test_foundation import client, credential
from test_patterns import ai, clock, dream, found, journal, organized, person, run_all, tasks_of


async def organized_dream(client, headers, user, tags=(('place', 'lake', 'lake'), ('place', 'pond', 'pond'), ('person', 'teacher', 'teacher'))):
    dream_id = await journal(client, headers, 'By the lake and the pond, my teacher waved.')
    await organized(user, dream_id, list(tags))
    return dream_id


async def correct(client, headers, dream_id, **body):
    return await client.put(f'/v1/dreams/{dream_id}/corrections', headers=headers, json=body)


async def organization(client, headers, dream_id):
    return (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream']['organization']


async def output_revision(dream_id):
    return (await db.rwdb.execute_fetchall("SELECT revision FROM outputs WHERE dream_id=? AND type='organization'", (dream_id,)))[0][0]


async def tagged(client, headers, tag):
    return [item['id'] for item in (await client.post('/v1/dreams/search', headers=headers, json={'tag': tag})).json()['items']]


async def test_requests_are_validated_and_need_a_current_organization(client, clock):
    headers, user = person()
    bare = await journal(client, headers, 'Not organized yet.')
    assert (await correct(client, headers, bare, category='summary', text='Mine.')).status_code == 409
    dream_id = await organized_dream(client, headers, user)
    cases = [({'category': 'feeling', 'text': 'x', 'original_text': 'lake'}, 400), ({'category': 'place', 'text': 'x'}, 400),
             ({'category': 'place', 'text': 'x', 'original_text': 'river'}, 400), ({'category': 'person', 'text': 'x', 'original_text': 'lake'}, 400),
             ({'category': 'summary', 'text': '   '}, 400), ({'category': 'place', 'text': 'x' * 61, 'original_text': 'lake'}, 413), ({'category': 'summary', 'text': 'y' * 601}, 413)]
    for body, status in cases:
        response = await correct(client, headers, dream_id, **body)
        assert response.status_code == status, (body, response.text)
    assert (await correct(client, credential(), dream_id, category='summary', text='Mine.')).status_code == 404
    assert (await client.put(f'/v1/dreams/{dream_id}/corrections', json={'category': 'summary', 'text': 'Mine.'})).status_code == 401
    assert await output_revision(dream_id) == 1
    await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': 1, 'text': 'A new account.', 'dream_date': '2026-10-10'})
    outdated = await correct(client, headers, dream_id, category='summary', text='Mine.')
    assert outdated.status_code == 409 and outdated.json()['error'] == 'invalid_state'


async def test_summary_correction_repeat_and_take_back(client, clock):
    headers, user = person()
    dream_id = await organized_dream(client, headers, user)
    indexing = len(await tasks_of('index_dream', dream_id))
    first = await correct(client, headers, dream_id, category='summary', text='  My own summary.  ')
    assert first.status_code == 200
    value = first.json()['dream']['organization']
    assert (value['summary'], value['summary_corrected'], await output_revision(dream_id)) == ('My own summary.', True, 2)
    assert (await client.get('/v1/dreams', headers=headers)).json()['items'][0]['summary'] == 'My own summary.'
    assert (await correct(client, headers, dream_id, category='summary', text='My own summary.')).status_code == 200 and await output_revision(dream_id) == 2
    back = (await correct(client, headers, dream_id, category='summary', text='A summary.')).json()['dream']['organization']
    assert (back['summary'], back['summary_corrected'], await output_revision(dream_id)) == ('A summary.', False, 3)
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM org_corrections') and len(await tasks_of('index_dream', dream_id)) == indexing


async def test_tag_rename_remove_restore_and_duplicates(client, clock):
    headers, user = person()
    dream_id = await organized_dream(client, headers, user)
    renamed = (await correct(client, headers, dream_id, category='place', original_text='LAKE', text='  Blue   LAKE ')).json()['dream']['organization']['tags']
    assert {(t['text'], t['original_text'], t['corrected'], t['removed']) for t in renamed if t['original_text'] == 'lake'} == {('blue lake', 'lake', True, False)}
    assert (await tagged(client, headers, 'blue lake'), await tagged(client, headers, 'lake')) == ([dream_id], [])
    removed = (await correct(client, headers, dream_id, category='place', original_text='lake', text='')).json()['dream']['organization']['tags']
    assert [(t['text'], t['removed']) for t in removed if t['original_text'] == 'lake'] == [('lake', True)] and await tagged(client, headers, 'blue lake') == []
    restored = (await correct(client, headers, dream_id, category='place', original_text='lake', text='lake')).json()['dream']['organization']['tags']
    assert [(t['text'], t['corrected']) for t in restored if t['original_text'] == 'lake'] == [('lake', False)] and await tagged(client, headers, 'lake') == [dream_id]
    revision = await output_revision(dream_id)
    merged = (await correct(client, headers, dream_id, category='place', original_text='pond', text='Lake')).json()['dream']['organization']['tags']
    assert [(t['text'], t['removed']) for t in merged if t['original_text'] == 'pond'] == [('pond', True)] and await output_revision(dream_id) == revision + 1
    assert (await db.rwdb.execute_fetchall("SELECT text FROM org_corrections WHERE original_text='pond'"))[0][0] == ''
    await correct(client, headers, dream_id, category='place', original_text='pond', text='Lake')
    assert await output_revision(dream_id) == revision + 1


async def test_a_correction_outdates_analyses_given_the_description(client, clock):
    headers, user = person()
    dream_id = await organized_dream(client, headers, user)
    output_id = (await db.rwdb.execute_fetchall("SELECT id FROM outputs WHERE dream_id=? AND type='organization'", (dream_id,)))[0][0]
    async with db.tx() as connection:
        await records.save_output(connection, user, dream_id, 'analysis', 1, {'sections': [], 'withheld': 0, 'removed_sources': 0, 'dream_date': '2026-10-10', 'mood': None}, 'test', 'analyze-1', [('DESC', 'output', output_id, 1, None, None)])
    await correct(client, headers, dream_id, category='person', original_text='teacher', text='coach')
    assert (await client.get(f'/v1/dreams/{dream_id}/analysis', headers=headers)).json()['analysis']['status'] == 'outdated'


async def test_a_tag_correction_resets_its_pattern_membership_and_reindexes(client, clock, ai):
    headers, user = person()
    first = await dream(client, headers, user, 'lake')
    second = await dream(client, headers, user, 'lake')
    group_id = (await found(client, headers))['findings'][0]['group_id']
    assert (await db.rwdb.execute_fetchall('SELECT label FROM pattern_groups WHERE id=?', (group_id,)))[0][0] is not None
    response = await correct(client, headers, first, category='object', original_text='the lake', text='The frozen lake')
    assert response.status_code == 200
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE dream_id=?', (first,))
    assert tuple((await db.rwdb.execute_fetchall('SELECT label,description,explanation FROM pattern_groups WHERE id=?', (group_id,)))[0]) == (None, None, None)
    assert [row['status'] for row in await tasks_of('refresh_findings', user=user)][-1] == 'waiting'
    assert [row['request_key'] for row in await tasks_of('index_dream', first)][-1] == f'index_dream:{first}:1:2:test-embedding-model:768'
    await run_all()
    assert (await db.rwdb.execute_fetchall('SELECT description FROM occurrences WHERE dream_id=?', (first,)))[0][0] == 'the frozen lake'
    assert {first, second} <= {row[0] for row in await db.rwdb.execute_fetchall('SELECT dream_id FROM pattern_memberships WHERE group_id=?', (group_id,))}
    calls = len(ai.calls)
    await correct(client, headers, first, category='summary', text='Only the summary changes.')
    assert [row['status'] for row in await tasks_of('index_dream', first)][-1] == 'completed' and len(ai.calls) == calls
