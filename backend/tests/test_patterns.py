import asyncio
import hashlib
import json
import math
import re
from datetime import datetime, timezone
from types import SimpleNamespace
from uuid import uuid4

import httpx
import msgspec
import pytest
import config
import db
import patterns
import providers
import records
import tasks
from test_foundation import client, credential

NOON = int(datetime(2026, 10, 10, 12, tzinfo=timezone.utc).timestamp() * 1000)
CONCEPTS = {'train': 0, 'classroom': 1, 'teacher': 2, 'lake': 3, 'dog': 4, 'fire': 5, 'exam': 6, 'station': 7, 'zebra': 8}


def vector_for(text):
    vector = [0.0] * config.EMBEDDING_DIMENSIONS
    for word, dimension in CONCEPTS.items():
        vector[dimension] += float(word in text.lower())
    vector[100 + int(hashlib.md5(text.encode()).hexdigest(), 16) % 600] += 0.3
    length = math.sqrt(sum(value * value for value in vector))
    return [value / length for value in vector]


def concept(text):
    return next((word for word in CONCEPTS if word in text.lower()), None)


def parsed(content):
    groups = {}
    for block in content.split('\n\n'):
        if found := re.match(r'(G\d+):', block):
            groups[found.group(1)] = {concept(description) for description in re.findall(r'^Example: \w+: (.+?)\. Excerpt:', block, re.M)}
    return re.findall(r'^(O\d+): \w+: (.+?)\. Excerpt:', content, re.M), re.findall(r'^(U\d+): \w+: (.+?)\. Excerpt:', content, re.M), groups


def decision(occurrence, action='none', target='', shared='', label='', description=''):
    return {'occurrence': occurrence, 'action': action, 'target': target, 'shared_element': shared, 'difference': '', 'label': label, 'description': description}


def sensible_match(content):
    occurrences, loose, groups = parsed(content)
    decisions = []
    for label, description in occurrences:
        theme = concept(description)
        group = next((name for name, themes in groups.items() if theme and theme in themes), None)
        other = next((name for name, text in loose if theme and concept(text) == theme), None)
        decisions.append(decision(label, 'join', group, f'shared {theme}') if group else decision(label, 'new_group', other, f'shared {theme}', f'{theme} theme', f'Dreams with a {theme}') if other else decision(label))
    return {'decisions': decisions}


def sensible_findings(content):
    entries = []
    for block in content.split('\n\n'):
        if found := re.match(r'(G\d+):\nSupporting recorded dreams: (\d+)', block):
            entries.append({'group': found.group(1), 'label': f'theme {concept(block) or "unknown"}', 'description': 'A shared situation.', 'explanation': f'This appears in {found.group(2)} recorded dreams.',
                            'members': [{'evidence': name, 'shared_element': 'shared situation', 'difference': ''} for name in re.findall(r'^(E\d+): ', block, re.M)]})
    return {'groups': entries}


@pytest.fixture
def clock(monkeypatch):
    now = {'ms': NOON}
    monkeypatch.setattr(config, 'now', lambda: now['ms'])
    return now


@pytest.fixture
def ai(monkeypatch):
    stand_in = SimpleNamespace(embeds=[], calls=[], match=sensible_match, findings=sensible_findings, fail_embed=None, on_embed=None)
    async def embed(texts, timeout=None):
        stand_in.embeds.append(list(texts))
        if stand_in.on_embed:
            await stand_in.on_embed()
        if stand_in.fail_embed:
            raise stand_in.fail_embed
        return [vector_for(text) for text in texts]
    async def complete_json(instruction, content, schema, name, answer_type, temperature=None):
        stand_in.calls.append(SimpleNamespace(instruction=instruction, content=content, name=name, temperature=temperature))
        answer = (stand_in.match if name == 'matching' else stand_in.findings)(content)
        answer = await answer if asyncio.iscoroutine(answer) else answer
        if isinstance(answer, Exception):
            raise answer
        return msgspec.convert(answer, answer_type)
    monkeypatch.setattr(providers, 'embed', embed)
    monkeypatch.setattr(providers, 'complete_json', complete_json)
    monkeypatch.setattr(tasks, 'handlers', {'index_dream': patterns.index_dream, 'match_patterns': patterns.match_patterns, 'refresh_findings': patterns.refresh_findings})
    return stand_in


async def journal(client, headers, text, dream_date='2026-10-10', **fields):
    dream_id = str(uuid4())
    response = await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': 0, 'text': text, 'dream_date': dream_date, 'source': 'text', 'title': f'Title {dream_date}', **fields})
    assert response.status_code == 201
    return dream_id


async def organized(user, dream_id, tags):
    async with db.tx() as connection:
        revision = (await connection.execute_fetchall('SELECT revision FROM dreams WHERE id=?', (dream_id,)))[0][0]
        output_id = await records.save_output(connection, user, dream_id, 'organization', revision, {'summary': 'A summary.'}, 'test', 'organize-1')
        await connection.executemany('INSERT INTO tags(id,output_id,dream_id,user_id,category,text,excerpt,feeling) VALUES(?,?,?,?,?,?,?,?)',
                                     [(str(uuid4()), output_id, dream_id, user, category, text, excerpt, feeling) for category, text, excerpt, *rest in tags for feeling in [rest[0] if rest else ('stated' if category == 'emotion' else None)]])
        await connection.execute("UPDATE tasks SET status='completed' WHERE dream_id=? AND type='organize'", (dream_id,))
        await records.schedule_processing(connection, dream_id)


async def run_all(limit=60):
    for _ in range(limit):
        if not await tasks.run_once():
            return
    raise AssertionError('tasks kept running')


async def dream(client, headers, user, theme, dream_date='2026-10-10', extra=(), text=None):
    dream_id = await journal(client, headers, text or f'I dreamt of a {theme} again, the {theme} was there.', dream_date)
    await organized(user, dream_id, [('object', f'the {theme}', theme), *extra])
    await run_all()
    return dream_id


async def found(client, headers, **query):
    response = await client.get('/v1/patterns', headers=headers, params=query)
    assert response.status_code == 200, response.text
    return response.json()


async def tasks_of(kind, dream_id=None, user=None):
    return await db.rwdb.execute_fetchall(f"SELECT * FROM tasks WHERE type=? AND {'dream_id' if dream_id else 'user_id'}=? ORDER BY rowid", (kind, dream_id or user))


async def text_units(user):
    rows = await db.rwdb.execute_fetchall("SELECT count FROM usage WHERE user_id=? AND kind='text'", (user,))
    return rows[0][0] if rows else 0


def person():
    headers = credential()
    return headers, headers['Authorization'][7:]


async def test_indexing_builds_vector_and_occurrences_once_per_state(client, clock, ai):
    headers, user = person()
    dream_id = await journal(client, headers, 'A train at a lake, and I felt afraid.')
    await organized(user, dream_id, [('object', 'train', 'train'), ('place', 'lake', 'lake'), ('emotion', 'fear', 'afraid', 'inferred'), ('emotion', 'calm', 'felt', 'stated')])
    [index] = await tasks_of('index_dream', dream_id)
    assert index['request_key'] == f'index_dream:{dream_id}:1:1:test-embedding-model:768'
    assert await tasks.run_once()
    assert (await tasks_of('index_dream', dream_id))[0]['status'] == 'completed' and ai.embeds[0][0] == 'A train at a lake, and I felt afraid.'
    assert sorted(ai.embeds[0][1:]) == ['emotion: calm. felt', 'object: train. train', 'place: lake. lake']
    vector = (await db.rwdb.execute_fetchall('SELECT * FROM dream_vectors WHERE dream_id=?', (dream_id,)))[0]
    assert (vector['dream_revision'], vector['model'], vector['dimensions'], len(vector['embedding'])) == (1, 'test-embedding-model', 768, 768 * 4)
    rows = await db.rwdb.execute_fetchall('SELECT description,model,dimensions FROM occurrences WHERE dream_id=? ORDER BY description', (dream_id,))
    assert [tuple(row) for row in rows] == [('calm', 'test-embedding-model', 768), ('lake', 'test-embedding-model', 768), ('train', 'test-embedding-model', 768)]
    assert await text_units(user) == 1 and [row['status'] for row in await tasks_of('match_patterns', dream_id)] == ['waiting']
    await db.rwdb.execute("UPDATE tasks SET status='waiting' WHERE type='index_dream' AND dream_id=?", (dream_id,))
    assert await tasks.run_once()
    assert len(await db.rwdb.execute_fetchall('SELECT 1 FROM occurrences WHERE dream_id=?', (dream_id,))) == 3 and len(await db.rwdb.execute_fetchall('SELECT 1 FROM dream_vectors')) == 1


async def test_which_dreams_get_a_vector_and_occurrences(client, clock, ai):
    headers, user = person()
    closed = await journal(client, headers, 'A dog by the fire.', permissions={'analysis': False})
    hidden = await journal(client, headers, 'A dog in the rain.', permissions={'patterns': False})
    failed = await journal(client, headers, 'A dog at the station.')
    await db.rwdb.execute("UPDATE tasks SET status='failed',error_code='provider_refused' WHERE dream_id=? AND type='organize'", (failed,))
    async with db.tx() as connection:
        await records.schedule_processing(connection, failed)
    assert not await tasks_of('organize', closed) and not await tasks_of('index_dream', hidden)
    await run_all()
    for dream_id, has_vector in ((closed, True), (hidden, False), (failed, True)):
        assert bool(await db.rwdb.execute_fetchall('SELECT 1 FROM dream_vectors WHERE dream_id=?', (dream_id,))) == has_vector
        assert not await db.rwdb.execute_fetchall('SELECT 1 FROM occurrences WHERE dream_id=?', (dream_id,))
    assert not await tasks_of('match_patterns', closed)


async def test_embedding_failures_and_missing_extension(client, clock, ai, monkeypatch):
    headers, user = person()
    ai.fail_embed = providers.ProviderError('network', True)
    dream_id = await journal(client, headers, 'A lake.')
    await organized(user, dream_id, [('place', 'lake', 'lake')])
    for delay in (0, 15000, 60000):
        clock['ms'] += delay
        assert await tasks.run_once()
    assert ((await tasks_of('index_dream', dream_id))[0]['status'], (await tasks_of('index_dream', dream_id))[0]['error_code']) == ('failed', 'network')
    ai.fail_embed = None
    monkeypatch.setattr(db, 'vectors', False)
    other = await journal(client, headers, 'A dog.')
    await organized(user, other, [('object', 'dog', 'dog')])
    assert await tasks.run_once()
    assert ((await tasks_of('index_dream', other))[0]['status'], (await tasks_of('index_dream', other))[0]['error_code'], await text_units(user)) == ('failed', 'vectors_unavailable', 3)
    assert (await found(client, headers))['available'] is False
    monkeypatch.setattr(db, 'vectors', True)
    await patterns.backfill()
    assert (await tasks_of('index_dream', other))[0]['status'] == 'waiting'
    real = db.vector_path
    monkeypatch.setattr(db, 'vector_path', lambda: '/nonexistent/vector')
    await db.load_vectors()
    assert db.vectors is False
    monkeypatch.setattr(db, 'vector_path', real)
    await db.load_vectors()
    assert db.vectors is True


async def test_backfill_spaces_indexing_of_unindexed_dreams(client, clock, ai):
    headers, user = person()
    first = await journal(client, headers, 'A lake.')
    clock['ms'] += 1000
    second = await journal(client, headers, 'A dog.')
    for dream_id, theme in ((first, 'lake'), (second, 'dog')):
        await organized(user, dream_id, [('object', theme, theme)])
    await db.rwdb.execute("DELETE FROM tasks WHERE type='index_dream'")
    clock['ms'] += 1000
    await patterns.backfill()
    rows = await db.rwdb.execute_fetchall("SELECT dream_id,run_after FROM tasks WHERE type='index_dream' ORDER BY run_after")
    assert [row['dream_id'] for row in rows] == [first, second] and rows[1]['run_after'] - rows[0]['run_after'] == 20000


async def test_candidates_cost_and_users(client, clock, ai, monkeypatch):
    headers, user = person()
    stranger_headers, stranger = person()
    for _ in range(3):
        await dream(client, stranger_headers, stranger, 'train')
    first = await dream(client, headers, user, 'train')
    assert len([call for call in ai.calls if call.name == 'matching']) == 2 and await text_units(user) == 1
    unrelated = await dream(client, headers, user, 'zebra')
    assert await text_units(user) == 2 and len([call for call in ai.calls if call.name == 'matching']) == 2
    same_tag = await dream(client, headers, user, 'train', extra=(('place', 'lake', 'dreamt'),))
    match_call = [call for call in ai.calls if call.name == 'matching'][-1]
    assert match_call.temperature == 0 and len(re.findall(r'^U\d+:', match_call.content, re.M)) == 1 and 'zebra' not in match_call.content
    assert await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE dream_id IN (?,?)', (first, same_tag))
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE dream_id=?', (unrelated,))
    stranger_groups = {row[0] for row in await db.rwdb.execute_fetchall('SELECT group_id FROM pattern_memberships WHERE user_id=?', (stranger,))}
    assert stranger_groups.isdisjoint(row[0] for row in await db.rwdb.execute_fetchall('SELECT group_id FROM pattern_memberships WHERE user_id=?', (user,)))


async def test_no_occurrence_gets_more_than_max_candidates(client, clock, ai, monkeypatch):
    headers, user = person()
    ai.match = lambda content: {'decisions': []}
    for description in ('the station', 'a station platform', 'station steps'):
        dream_id = await journal(client, headers, f'I stood at {description}.')
        await organized(user, dream_id, [('place', description, description)])
        await run_all()
    offered = [call for call in ai.calls if call.name == 'matching'][-1]
    assert len(re.findall(r'^U\d+:', offered.content, re.M)) == 2
    monkeypatch.setattr(config, 'MAX_CANDIDATES', 1)
    last = await journal(client, headers, 'Back at the station.')
    await organized(user, last, [('place', 'the station hall', 'station')])
    await run_all()
    assert len(re.findall(r'^U\d+:', [call for call in ai.calls if call.name == 'matching'][-1].content, re.M)) == 1


async def test_meaning_candidates_and_cut_off(client, clock, ai, monkeypatch):
    headers, user = person()
    first = await journal(client, headers, 'Missed it.')
    await organized(user, first, [('action', 'running for the train', 'Missed')])
    await run_all()
    near = await journal(client, headers, 'Late again.')
    await organized(user, near, [('action', 'the departing train', 'Late')])
    await run_all()
    call = [call for call in ai.calls if call.name == 'matching'][-1]
    assert 'running for the train' in call.content.split('Ungrouped candidates:')[1]
    monkeypatch.setattr(config, 'MAX_CANDIDATE_DISTANCE', 0.01)
    far = await journal(client, headers, 'Once more.')
    await organized(user, far, [('action', 'a train whistle', 'Once')])
    calls = len(ai.calls)
    await run_all()
    assert len([call for call in ai.calls[calls:] if call.name == 'matching']) == 0


async def test_decision_checks_and_no_merging(client, clock, ai):
    headers, user = person()
    await dream(client, headers, user, 'dog')
    await dream(client, headers, user, 'dog')
    await dream(client, headers, user, 'fire')
    await dream(client, headers, user, 'fire')
    groups = [row[0] for row in await db.rwdb.execute_fetchall('SELECT id FROM pattern_groups WHERE user_id=? ORDER BY created_at', (user,))]
    assert len(groups) == 2
    def greedy(content):
        _, _, group_labels = parsed(content)
        return {'decisions': [decision('O1', 'join', label, 'both') for label in group_labels] + [decision('O9', 'join', 'G1', 'x'), decision('O1', 'new_group', 'U1', '')]}
    ai.match = greedy
    both = await dream(client, headers, user, 'dog', extra=(('object', 'fire', 'dog'),))
    memberships = await db.rwdb.execute_fetchall('SELECT group_id FROM pattern_memberships WHERE dream_id=?', (both,))
    assert len(memberships) == 1 and len(await db.rwdb.execute_fetchall('SELECT id FROM pattern_groups WHERE user_id=?', (user,))) == 2
    ai.match = lambda content: {'decisions': [decision('O1', 'join', 'G1', '   ')]}
    lonely = await dream(client, headers, user, 'dog')
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE dream_id=?', (lonely,))
    ai.match = lambda content: {'decisions': [decision('O1', 'new_group', 'U1', 'shared', '', 'description')]}
    unlabeled = await dream(client, headers, user, 'zebra')
    await dream(client, headers, user, 'zebra')
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE dream_id=?', (unlabeled,))
    provenance = await db.rwdb.execute_fetchall('SELECT model,instruction_version FROM pattern_memberships WHERE user_id=? UNION SELECT model,instruction_version FROM pattern_groups WHERE user_id=?', (user, user))
    assert {tuple(row) for row in provenance} <= {('test-text-model', 'match-1'), ('test-text-model', 'findings-1')}


async def test_findings_counts_thresholds_and_trend(client, clock, ai):
    headers, user = person()
    assert (await found(client, headers))['insufficient_history'] is True
    await dream(client, headers, user, 'lake', '2026-09-01')
    await dream(client, headers, user, 'lake', '2026-09-20', extra=(('place', 'the lake shore', 'lake'),))
    related = await found(client, headers, from_date='2026-09-15', to_date='2026-10-14')
    assert [(f['kind'], f['supporting_dreams'], f['status']) for f in related['findings']] == [('related', 2, 'current')]
    await dream(client, headers, user, 'lake', '2026-10-05')
    await dream(client, headers, user, 'zebra', '2026-10-06')
    result = await found(client, headers, from_date='2026-09-15', to_date='2026-10-14')
    finding = result['findings'][0]
    group_id = finding['group_id']
    direct = await db.rwdb.execute_fetchall('SELECT COUNT(DISTINCT m.dream_id) FROM pattern_memberships m JOIN current_occurrences c ON c.tag_id=m.tag_id WHERE m.group_id=?', (group_id,))
    assert (finding['kind'], finding['supporting_dreams'], direct[0][0]) == ('recurring', 3, 3)
    assert (finding['period_count'], result['eligible_dreams'], finding['previous_count'], result['previous_eligible_dreams']) == (2, 3, 1, 1)
    assert finding['trend'] == 'less_often_recorded_recently' and result['period'] == {'from_date': '2026-09-15', 'to_date': '2026-10-14'}
    assert finding['explanation'] == 'This appears in 3 recorded dreams.' and finding['label'] == 'theme lake' and len(finding['examples']) == 4
    assert [example['dream_date'] for example in finding['examples']] == sorted((example['dream_date'] for example in finding['examples']), reverse=True)
    assert (await client.get('/v1/patterns', headers=headers, params={'from_date': '2026-09-01'})).status_code == 400
    assert (await client.get('/v1/patterns', headers=headers, params={'from_date': '2026-10-02', 'to_date': '2026-10-01'})).status_code == 400


async def test_refresh_number_check_no_repeat_and_one_more_try(client, clock, ai):
    headers, user = person()
    ai.findings = lambda content: {'groups': [dict(entry, explanation='Seen 7 times in 2026.') for entry in sensible_findings(content)['groups']]}
    await dream(client, headers, user, 'exam')
    await dream(client, headers, user, 'exam')
    finding = (await found(client, headers))['findings'][0]
    assert (finding['explanation'], finding['label'], finding['status']) == ('Found in 2 recorded dreams.', 'theme exam', 'current')
    ai.findings = lambda content: {'groups': [dict(entry, explanation='Each one shows an exam; 3 recorded dreams.') for entry in sensible_findings(content)['groups']]}
    await dream(client, headers, user, 'exam')
    assert (await found(client, headers))['findings'][0]['explanation'] == 'Each one shows an exam; 3 recorded dreams.'
    units, refreshes = await text_units(user), len(await tasks_of('refresh_findings', user=user))
    ai.findings = lambda content: {'groups': [{'group': 'G1', 'label': '', 'description': '', 'explanation': '', 'members': []}]}
    async with db.tx() as connection:
        await patterns.clear_group_texts(connection, finding['group_id'])
        await patterns.schedule_refresh(connection, user)
    await run_all()
    plain = (await found(client, headers))['findings'][0]
    assert (plain['label'], plain['explanation'], plain['status'], await text_units(user)) == (None, 'Found in 3 recorded dreams.', 'current', units + 2)
    await found(client, headers)
    await found(client, headers)
    assert len(await tasks_of('refresh_findings', user=user)) == refreshes + 1


async def test_refresh_combining_and_group_deletion(client, clock, ai):
    headers, user = person()
    await dream(client, headers, user, 'fire')
    await dream(client, headers, user, 'fire')
    group_id = (await found(client, headers))['findings'][0]['group_id']
    async with db.tx() as connection:
        for _ in range(3):
            await patterns.schedule_refresh(connection, user)
    assert len([row for row in await tasks_of('refresh_findings', user=user) if row['status'] == 'waiting']) == 1
    await db.rwdb.execute('DELETE FROM pattern_memberships WHERE group_id=?', (group_id,))
    await run_all()
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_groups WHERE id=?', (group_id,))
    await dream(client, headers, user, 'dog')
    await dream(client, headers, user, 'dog')
    kept = (await found(client, headers))['findings'][0]['group_id']
    await client.put(f'/v1/patterns/groups/{kept}/label', headers=headers, json={'label': 'My dogs'})
    await db.rwdb.execute('DELETE FROM pattern_memberships WHERE group_id=?', (kept,))
    async with db.tx() as connection:
        await patterns.schedule_refresh(connection, user)
    await run_all()
    assert await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_groups WHERE id=?', (kept,))


async def test_edit_delete_and_exclusion_invalidate_findings(client, clock, ai):
    headers, user = person()
    ai.findings = lambda content: {'groups': [dict(entry, label='zebra marker theme', description='zebra marker described') for entry in sensible_findings(content)['groups']]}
    first = await dream(client, headers, user, 'zebra')
    second = await dream(client, headers, user, 'zebra')
    third = await dream(client, headers, user, 'zebra')
    finding = (await found(client, headers))['findings'][0]
    assert finding['status'] == 'current' and finding['label'] == 'zebra marker theme'
    await client.put(f'/v1/dreams/{third}', headers=headers, json={'base_revision': 1, 'text': 'Now a different account.', 'dream_date': '2026-10-10'})
    edited = (await found(client, headers))['findings'][0]
    assert (edited['status'], edited['explanation'], edited['supporting_dreams']) == ('refreshing', None, 2) and third not in [e['dream_id'] for e in edited['examples']]
    group = (await db.rwdb.execute_fetchall('SELECT * FROM pattern_groups WHERE id=?', (finding['group_id'],)))[0]
    assert (group['label'], group['description'], group['explanation']) == (None, None, None)
    assert not await db.rwdb.execute_fetchall("SELECT 1 FROM pattern_memberships WHERE shared_element IS NOT NULL AND group_id=?", (finding['group_id'],))
    await client.put(f'/v1/patterns/groups/{finding["group_id"]}/label', headers=headers, json={'label': 'Mine'})
    await client.delete(f'/v1/dreams/{second}', headers=headers)
    small = await db.rwdb.execute_fetchall('SELECT label,description,explanation,user_label FROM pattern_groups WHERE id=?', (finding['group_id'],))
    assert tuple(small[0]) == (None, None, None, 'Mine') and (await found(client, headers))['findings'] == []
    assert not await db.rwdb.execute_fetchall("SELECT 1 FROM pattern_groups WHERE label LIKE '%marker%' OR description LIKE '%marker%' OR explanation LIKE '%marker%'")
    assert not await db.rwdb.execute_fetchall("SELECT 1 FROM pattern_memberships WHERE shared_element LIKE '%marker%' OR difference LIKE '%marker%'")
    headers, user = person()
    dreams_ = [await dream(client, headers, user, 'dog', f'2026-10-0{day}') for day in (1, 2, 3)]
    await run_all()
    excluded_group = (await found(client, headers))['findings'][0]['group_id']
    await client.put(f'/v1/dreams/{dreams_[0]}/permissions', headers=headers, json={'patterns': False})
    assert tuple((await db.rwdb.execute_fetchall('SELECT label,description,explanation FROM pattern_groups WHERE id=?', (excluded_group,)))[0]) == (None, None, None)
    excluded = await found(client, headers)
    assert excluded['findings'][0]['supporting_dreams'] == 2 and excluded['eligible_dreams'] == 2 and dreams_[0] not in [e['dream_id'] for e in excluded['findings'][0]['examples']]
    calls = len(ai.calls)
    await client.put(f'/v1/dreams/{dreams_[0]}/permissions', headers=headers, json={'patterns': True})
    await run_all()
    back = await found(client, headers)
    assert back['findings'][0]['supporting_dreams'] == 3 and len([call for call in ai.calls[calls:] if call.name == 'matching']) == 0


async def test_date_or_title_change_keeps_evidence(client, clock, ai):
    headers, user = person()
    first = await dream(client, headers, user, 'lake', '2026-10-01')
    await dream(client, headers, user, 'lake', '2026-10-02')
    before = (await found(client, headers))['findings'][0]
    refreshes = len(await tasks_of('refresh_findings', user=user))
    await client.put(f'/v1/dreams/{first}', headers=headers, json={'base_revision': 1, 'text': 'I dreamt of a lake again, the lake was there.', 'dream_date': '2026-08-01', 'title': 'Renamed'})
    after = (await found(client, headers))['findings'][0]
    assert (after['status'], after['explanation']) == ('current', before['explanation']) and len(await tasks_of('refresh_findings', user=user)) == refreshes
    assert after['period_count'] == 1 and before['period_count'] == 2


async def test_dismissal_constraint_notes_and_repeats(client, clock, ai):
    headers, user = person()
    a, b, c = [await dream(client, headers, user, 'teacher') for _ in range(3)]
    group_id = (await found(client, headers))['findings'][0]['group_id']
    url = f'/v1/patterns/groups/{group_id}/dismiss'
    assert (await client.post(url, headers=headers, json={'dream_id': a, 'note': 'x' * 301})).status_code == 413
    assert (await client.post(url, headers=headers, json={'dream_id': str(uuid4())})).status_code == 404
    assert (await client.post(url, headers=headers, json={'dream_id': a, 'note': 'Two different teachers.'})).status_code == 200
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE dream_id=?', (a,))
    assert await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_separations WHERE dream_id IN (?,?) AND other_dream_id IN (?,?)', (a, b, a, b))
    await run_all()
    label, refreshes = (await db.rwdb.execute_fetchall('SELECT label FROM pattern_groups WHERE id=?', (group_id,)))[0][0], len(await tasks_of('refresh_findings', user=user))
    await client.post(url, headers=headers, json={'dream_id': a, 'note': 'Two different teachers.'})
    assert label is not None and (await db.rwdb.execute_fetchall('SELECT label FROM pattern_groups WHERE id=?', (group_id,)))[0][0] == label
    assert len(await tasks_of('refresh_findings', user=user)) == refreshes
    await dream(client, headers, user, 'teacher')
    offered = [call for call in ai.calls if call.name == 'matching'][-1]
    assert 'Two different teachers.' in offered.content and 'Two different teachers.' not in offered.instruction
    finding = next(f for f in (await found(client, headers))['findings'] if f['group_id'] == group_id)
    assert finding['notes'] == ['Two different teachers.'] and finding['dismissal_notes'] == [{'dream_id': a, 'note': 'Two different teachers.'}]
    await client.put(f'/v1/dreams/{a}/permissions', headers=headers, json={'patterns': False})
    await dream(client, headers, user, 'teacher')
    assert 'Two different teachers.' not in [call for call in ai.calls if call.name == 'matching'][-1].content
    await client.put(f'/v1/dreams/{a}/permissions', headers=headers, json={'patterns': True})
    await run_all()
    await dream(client, headers, user, 'teacher')
    assert 'Two different teachers.' in [call for call in ai.calls if call.name == 'matching'][-1].content
    await client.post(url, headers=headers, json={'dream_id': a, 'note': ''})
    cleared = next(f for f in (await found(client, headers))['findings'] if f['group_id'] == group_id)
    assert (cleared['notes'], cleared['dismissal_notes']) == ([], []) and await db.rwdb.execute_fetchall("SELECT 1 FROM pattern_corrections WHERE dream_id=? AND kind='dismissed'", (a,))
    assert (await client.post(url, headers=headers, json={'dream_id': c, 'note': ''})).status_code == 200
    assert (await client.post(url, headers=headers, json={'dream_id': await dream(client, headers, user, 'zebra')})).status_code == 409


async def edited(client, headers, user, dream_id, tags):
    revision = (await db.rwdb.execute_fetchall('SELECT revision FROM dreams WHERE id=?', (dream_id,)))[0][0]
    response = await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': revision, 'text': f'Edited account {uuid4()}.', 'dream_date': '2026-10-10'})
    assert response.status_code == 200 and response.json()['dream']['revision'] == revision + 1
    await organized(user, dream_id, tags)
    await run_all()


async def groups_with(*dream_ids):
    rows = await db.rwdb.execute_fetchall(f"SELECT group_id,dream_id FROM pattern_memberships WHERE dream_id IN ({','.join('?' * len(dream_ids))})", dream_ids)
    members = {}
    for row in rows:
        members.setdefault(row['group_id'], set()).add(row['dream_id'])
    return list(members.values())


async def test_a_dismissal_holds_after_its_partners_leave(client, clock, ai):
    headers, user = person()
    a, b = [await dream(client, headers, user, 'teacher') for _ in range(2)]
    group_id = (await found(client, headers))['findings'][0]['group_id']
    await client.post(f'/v1/patterns/groups/{group_id}/dismiss', headers=headers, json={'dream_id': a})
    c = await dream(client, headers, user, 'teacher')
    assert (await db.rwdb.execute_fetchall('SELECT group_id FROM pattern_memberships WHERE dream_id=?', (c,)))[0][0] == group_id
    await client.delete(f'/v1/dreams/{b}', headers=headers)
    await edited(client, headers, user, a, [('person', 'the teacher', 'teacher')])
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE dream_id=? AND group_id=?', (a, group_id))


async def test_a_separation_blocks_other_groups_and_loose_occurrences(client, clock, ai):
    headers, user = person()
    a = await dream(client, headers, user, 'teacher')
    b = await dream(client, headers, user, 'teacher', extra=(('object', 'the dog', 'dog'), ('object', 'the fire', 'fire')))
    teacher_group = (await found(client, headers))['findings'][0]['group_id']
    await client.post(f'/v1/patterns/groups/{teacher_group}/dismiss', headers=headers, json={'dream_id': a})
    c = await dream(client, headers, user, 'dog')
    assert {b, c} in await groups_with(b, c)
    for tags in ([('object', 'a dog', 'dog')], [('object', 'a fire', 'fire')]):
        calls = len(ai.calls)
        await edited(client, headers, user, a, tags)
        assert all(not {a, b} <= members for members in await groups_with(a, b))
        assert all('the fire' not in call.content and 'the dog' not in call.content for call in ai.calls[calls:] if call.name == 'matching')


async def test_a_split_keeps_its_dreams_out_of_new_groups(client, clock, ai):
    headers, user = person()
    a, b, c = [await dream(client, headers, user, 'station') for _ in range(3)]
    group_id = (await found(client, headers))['findings'][0]['group_id']
    await client.post(f'/v1/patterns/groups/{group_id}/split', headers=headers, json={'dream_ids': [c]})
    ai.match = lambda content: {'decisions': []}
    await edited(client, headers, user, a, [('place', 'the station', 'station')])
    assert not await groups_with(a)
    ai.match = sensible_match
    await edited(client, headers, user, c, [('place', 'the station', 'station')])
    assert all(not (c in members and members & {a, b}) for members in await groups_with(a, b, c))


async def test_a_second_decision_for_an_occurrence_is_dropped(client, clock, ai):
    headers, user = person()
    ai.match = lambda content: {'decisions': [decision('O1'), decision('O1', 'new_group', 'U1', 'shared', 'label', 'description')]}
    await dream(client, headers, user, 'exam')
    await dream(client, headers, user, 'exam')
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE user_id=?', (user,))


async def test_tried_evidence_is_not_sent_again(client, clock, ai):
    headers, user = person()
    await dream(client, headers, user, 'lake')
    await dream(client, headers, user, 'lake')
    group_id = (await found(client, headers))['findings'][0]['group_id']
    removed = {}
    async def change_during_call(content):
        row = (await db.rwdb.execute_fetchall('SELECT * FROM pattern_memberships WHERE group_id=? LIMIT 1', (group_id,)))[0]
        removed.update(dict(row))
        await db.rwdb.execute('DELETE FROM pattern_memberships WHERE tag_id=?', (row['tag_id'],))
        return sensible_findings(content)
    ai.findings = change_during_call
    async with db.tx() as connection:
        await patterns.clear_group_texts(connection, group_id)
        await patterns.schedule_refresh(connection, user)
    await run_all()
    await db.rwdb.execute(f"INSERT INTO pattern_memberships({','.join(removed)}) VALUES({','.join('?' * len(removed))})", tuple(removed.values()))
    ai.findings = sensible_findings
    refreshes, calls = len(await tasks_of('refresh_findings', user=user)), len(ai.calls)
    finding = (await found(client, headers))['findings'][0]
    await run_all()
    assert finding['status'] == 'refreshing' and len(await tasks_of('refresh_findings', user=user)) == refreshes and len(ai.calls) == calls


async def test_a_new_member_hides_the_old_explanation(client, clock, ai):
    headers, user = person()
    await dream(client, headers, user, 'dog')
    await dream(client, headers, user, 'dog')
    assert (await found(client, headers))['findings'][0]['explanation'] == 'This appears in 2 recorded dreams.'
    third = await journal(client, headers, 'I dreamt of a dog again.')
    await organized(user, third, [('object', 'the dog', 'dog')])
    assert await tasks.run_once() and await tasks.run_once()
    finding = (await found(client, headers))['findings'][0]
    assert (finding['status'], finding['explanation'], finding['supporting_dreams']) == ('refreshing', None, 3)


async def test_a_deleted_example_during_matching_changes_the_context(client, clock, ai):
    headers, user = person()
    a, b = [await dream(client, headers, user, 'fire') for _ in range(2)]
    async def delete_during_call(content):
        await client.delete(f'/v1/dreams/{a}', headers=headers)
        return sensible_match(content)
    ai.match = delete_during_call
    c = await journal(client, headers, 'I dreamt of a fire again.')
    await organized(user, c, [('object', 'the fire', 'fire')])
    assert await tasks.run_once() and await tasks.run_once()
    matching = (await tasks_of('match_patterns', c))[0]
    assert (matching['status'], matching['error_code']) == ('waiting', 'context_changed') and not await groups_with(c)
    ai.match = sensible_match
    clock['ms'] += 15000
    await run_all()
    assert {b, c} in await groups_with(b, c)


async def test_corrections_during_indexing_and_removed_tags(client, clock, ai):
    headers, user = person()
    dream_id = await journal(client, headers, 'A train and a dog.')
    await organized(user, dream_id, [('object', 'train', 'train'), ('object', 'dog', 'dog')])
    output_id = (await db.rwdb.execute_fetchall("SELECT id FROM outputs WHERE dream_id=? AND type='organization'", (dream_id,)))[0][0]
    async def correct_during_call():
        ai.on_embed = None
        await db.rwdb.execute('UPDATE outputs SET revision=revision+1 WHERE id=?', (output_id,))
    ai.on_embed = correct_during_call
    assert await tasks.run_once()
    rows = await tasks_of('index_dream', dream_id)
    assert rows[0]['status'] == 'obsolete' and rows[1]['request_key'] == f'index_dream:{dream_id}:1:2:test-embedding-model:768' and rows[1]['status'] == 'waiting'
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM occurrences WHERE dream_id=?', (dream_id,))
    await run_all()
    assert len(await db.rwdb.execute_fetchall('SELECT 1 FROM occurrences WHERE dream_id=?', (dream_id,))) == 2
    async with db.tx() as connection:
        await connection.execute("INSERT INTO org_corrections(output_id,category,original_text,text,user_id,updated_at) VALUES(?,'object','dog','',?,1)", (output_id, user))
        await connection.execute('UPDATE outputs SET revision=revision+1 WHERE id=?', (output_id,))
        await records.schedule_processing(connection, dream_id)
    await run_all()
    assert [row[0] for row in await db.rwdb.execute_fetchall('SELECT description FROM occurrences WHERE dream_id=?', (dream_id,))] == ['train']


async def test_split_keeps_both_sides_apart(client, clock, ai):
    headers, user = person()
    a, b, c = [await dream(client, headers, user, 'station') for _ in range(3)]
    group_id = (await found(client, headers))['findings'][0]['group_id']
    url = f'/v1/patterns/groups/{group_id}/split'
    assert (await client.post(url, headers=headers, json={'dream_ids': [a, b, c]})).status_code == 409
    split = await client.post(url, headers=headers, json={'dream_ids': [c], 'label': 'Another station', 'note': 'C is a different place.'})
    assert split.status_code == 200
    assert (await client.post(url, headers=headers, json={'dream_ids': [c]})).status_code == 409
    new_group = (await db.rwdb.execute_fetchall('SELECT group_id FROM pattern_memberships WHERE dream_id=?', (c,)))[0][0]
    assert new_group != group_id and (await db.rwdb.execute_fetchall('SELECT user_label FROM pattern_groups WHERE id=?', (new_group,)))[0][0] == 'Another station'
    kinds = {(row['group_id'], row['dream_id']) for row in await db.rwdb.execute_fetchall("SELECT group_id,dream_id FROM pattern_corrections WHERE kind='split'")}
    assert kinds == {(group_id, c), (new_group, a), (new_group, b)}
    for target in (a, c):
        await client.put(f'/v1/dreams/{target}', headers=headers, json={'base_revision': 1, 'text': f'Edited {target} at the station.', 'dream_date': '2026-10-10'})
        await organized(user, target, [('place', 'the station', 'station')])
        await run_all()
    rows = await db.rwdb.execute_fetchall('SELECT group_id,dream_id FROM pattern_memberships WHERE dream_id IN (?,?,?)', (a, b, c))
    by_group = {}
    for row in rows:
        by_group.setdefault(row['group_id'], set()).add(row['dream_id'])
    assert by_group and all(not (c in members and members & {a, b}) for members in by_group.values())
    notes = {f['group_id']: f['notes'] for f in (await found(client, headers))['findings']}
    assert notes.get(group_id) == ['C is a different place.']
    assert 'Another station' not in ''.join(call.content for call in ai.calls)


async def test_deleting_a_dream_empties_split_notes(client, clock, ai):
    headers, user = person()
    a, b, c, d = [await dream(client, headers, user, 'fire') for _ in range(4)]
    group_id = (await found(client, headers))['findings'][0]['group_id']
    await client.post(f'/v1/patterns/groups/{group_id}/split', headers=headers, json={'dream_ids': [c, d], 'note': 'Note about C.'})
    await client.delete(f'/v1/dreams/{c}', headers=headers)
    rows = await db.rwdb.execute_fetchall("SELECT dream_id,note FROM pattern_corrections WHERE kind='split' ORDER BY dream_id")
    assert {row['dream_id'] for row in rows} == {a, b, d} and all(row['note'] == '' for row in rows)
    assert all(f['notes'] == [] for f in (await found(client, headers))['findings'])


async def test_switch_off_makes_matching_obsolete_until_turned_on(client, clock, ai):
    headers, user = person()
    await dream(client, headers, user, 'dog')
    dream_id = await journal(client, headers, 'I dreamt of a dog again.')
    await organized(user, dream_id, [('object', 'the dog', 'dog')])
    assert await tasks.run_once()
    await client.put(f'/v1/dreams/{dream_id}/permissions', headers=headers, json={'analysis': False})
    await run_all()
    assert (await tasks_of('match_patterns', dream_id))[0]['status'] == 'obsolete'
    await client.put(f'/v1/dreams/{dream_id}/permissions', headers=headers, json={'analysis': True})
    assert (await tasks_of('match_patterns', dream_id))[0]['status'] == 'waiting'
    await run_all()
    assert await db.rwdb.execute_fetchall('SELECT 1 FROM pattern_memberships WHERE dream_id=?', (dream_id,))


async def test_routes_require_ownership_and_valid_input(client, clock, ai):
    headers, user = person()
    await dream(client, headers, user, 'lake')
    await dream(client, headers, user, 'lake')
    group_id = (await found(client, headers))['findings'][0]['group_id']
    other = credential()
    for method, path, body in (('PUT', 'label', {'label': 'x'}), ('POST', 'dismiss', {'dream_id': str(uuid4())}), ('POST', 'split', {'dream_ids': [str(uuid4())]})):
        assert (await client.request(method, f'/v1/patterns/groups/{group_id}/{path}', headers=other, json=body)).status_code == 404
    assert (await client.put(f'/v1/patterns/groups/{group_id}/label', headers=headers, json={'label': 'x' * 61})).status_code == 413
    labeled = await client.put(f'/v1/patterns/groups/{group_id}/label', headers=headers, json={'label': '  Lakes  '})
    assert (labeled.json()['findings'][0]['label'], labeled.json()['findings'][0]['label_corrected']) == ('Lakes', True)
    await dream(client, headers, user, 'lake')
    assert 'Lakes' not in [call for call in ai.calls if call.name == 'matching'][-1].content
    cleared = await client.put(f'/v1/patterns/groups/{group_id}/label', headers=headers, json={'label': None})
    assert cleared.json()['findings'][0]['label_corrected'] is False
    assert (await client.get('/v1/patterns')).status_code == 401 and (await client.post(f'/v1/patterns/groups/{group_id}/split', headers=headers, json={'dream_ids': []})).status_code == 400


@pytest.fixture
def endpoint(monkeypatch):
    monkeypatch.setenv('EMBEDDING_MODEL', 'test-embedding-model')
    monkeypatch.setenv('GEMINI_API_KEY', 'secret-key-value')
    seen = []
    def install(handler):
        async def recorded(request):
            seen.append(request)
            return await handler(request)
        monkeypatch.setattr(providers, 'client', httpx.AsyncClient(transport=httpx.MockTransport(recorded)))
    return SimpleNamespace(install=install, seen=seen)


async def test_embed_adapter_request_scaling_and_errors(endpoint, monkeypatch, caplog):
    async def answer(request):
        return httpx.Response(200, json={'embedding': {'values': [3.0, 4.0] + [0.0] * 766}})
    endpoint.install(answer)
    vectors = await providers.embed(['one', 'two'])
    request = endpoint.seen[0]
    assert str(request.url) == 'https://generativelanguage.googleapis.com/v1beta/models/test-embedding-model:embedContent' and request.headers['x-goog-api-key'] == 'secret-key-value'
    assert json.loads(request.content) == {'content': {'parts': [{'text': 'one'}]}, 'output_dimensionality': 768}
    assert len(vectors) == 2 and vectors[0][:2] == [0.6, 0.8] and len(endpoint.seen) == 2
    for status, body, category in ((200, {'embedding': {'values': [1.0] * 10}}, 'invalid_output'), (200, {'nothing': 1}, 'invalid_output'), (402, {}, 'provider_config'), (429, {}, 'rate_limited'), (503, {}, 'provider_unavailable')):
        async def failing(request, status=status, body=body):
            return httpx.Response(status, json=body)
        endpoint.install(failing)
        with pytest.raises(providers.ProviderError) as raised:
            await providers.embed(['x'])
        assert raised.value.category == category
    monkeypatch.setattr(config, 'PROVIDER_TIMEOUT_SECONDS', 0.15)
    async def slow(request):
        await asyncio.sleep(0.06)
        return httpx.Response(200, json={'embedding': {'values': [1.0] + [0.0] * 767}})
    endpoint.install(slow)
    with pytest.raises(providers.ProviderError) as raised:
        await providers.embed(['a', 'b', 'c', 'd'])
    assert raised.value.category == 'network' and 'secret-key-value' not in caplog.text
