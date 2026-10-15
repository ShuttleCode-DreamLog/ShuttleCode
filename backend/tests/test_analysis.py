import json
import re
from datetime import date, datetime, timezone
from types import SimpleNamespace
from uuid import uuid4

import msgspec
import pytest
import analysis
import config
import db
import dreams
import providers
import records
import tasks
from test_foundation import client, credential

NOON = int(datetime(2026, 10, 10, 12, tzinfo=timezone.utc).timestamp() * 1000)
DAY = 24 * 3600 * 1000
TEXT = 'I missed the train to the station and the lake was frozen. My teacher waved.'


@pytest.fixture
def clock(monkeypatch):
    now = {'ms': NOON}
    monkeypatch.setattr(config, 'now', lambda: now['ms'])
    return now


@pytest.fixture
def gemini(monkeypatch):
    stand_in = SimpleNamespace(calls=[], answers=[])
    async def complete_json(instruction, content, schema, name, answer_type, temperature=None):
        stand_in.calls.append({'instruction': instruction, 'content': content, 'name': name, 'temperature': temperature})
        answer = stand_in.answers.pop(0)
        answer = await answer() if callable(answer) else answer
        if isinstance(answer, Exception):
            raise answer
        return msgspec.convert(answer, answer_type)
    monkeypatch.setattr(providers, 'complete_json', complete_json)
    monkeypatch.setattr(tasks, 'handlers', {'analyze': analysis.analyze})
    return stand_in


def section(kind, text='A grounded reading.', citations=('DREAM',)):
    return {'kind': kind, 'text': text, 'citations': list(citations)}


BASE = [section('what_happened', 'You missed a train by a frozen lake.'), section('reflection_questions', 'What did the frozen lake feel like?')]


async def journal(client, text=TEXT, headers=None, dream_date='2026-10-10', **fields):
    headers = headers or credential()
    dream_id = str(uuid4())
    body = {'base_revision': 0, 'text': text, 'dream_date': dream_date, 'source': 'text', 'title': 'Train title', **fields}
    assert (await client.put(f'/v1/dreams/{dream_id}', headers=headers, json=body)).status_code == 201
    return headers, headers['Authorization'][7:], dream_id


async def organized(user, dream_id, summary='A missed train.', tags=(('object', 'train', 'train'), ('place', 'lake', 'lake'))):
    async with db.tx() as connection:
        revision = (await connection.execute_fetchall('SELECT revision FROM dreams WHERE id=?', (dream_id,)))[0][0]
        output_id = await records.save_output(connection, user, dream_id, 'organization', revision, {'summary': summary}, 'test', 'organize-1')
        await connection.executemany('INSERT INTO tags(id,output_id,dream_id,user_id,category,text,excerpt,feeling) VALUES(?,?,?,?,?,?,?,?)',
                                     [(str(uuid4()), output_id, dream_id, user, category, text, excerpt, 'stated' if category == 'emotion' else None) for category, text, excerpt in tags])
        await connection.execute("UPDATE tasks SET status='completed' WHERE dream_id=? AND type='organize'", (dream_id,))
        await records.schedule_processing(connection, dream_id)
    return output_id


async def note(client, headers, text, **fields):
    memory_id = str(uuid4())
    response = await client.put(f'/v1/memories/{memory_id}', headers=headers, json={'base_revision': 0, 'text': text, **fields})
    assert response.status_code == 201
    return memory_id


async def context(dream_id, use_history=1):
    async with db.tx() as connection:
        dream = (await connection.execute_fetchall('SELECT * FROM dreams WHERE id=?', (dream_id,)))[0]
        return await analysis.select_context(connection, dream, use_history)


async def stored(dream_id):
    rows = await db.rwdb.execute_fetchall("SELECT * FROM outputs WHERE dream_id=? AND type='analysis'", (dream_id,))
    return [dict(row) | {'content': json.loads(row['content'])} for row in rows]


async def analyze_task(dream_id):
    return (await db.rwdb.execute_fetchall("SELECT * FROM tasks WHERE dream_id=? AND type='analyze' ORDER BY rowid DESC", (dream_id,)))[0]


def test_term_matching_words_and_terms():
    assert analysis.term_in('car', 'A red car.') and not analysis.term_in('car', 'I was scared') and not analysis.term_in('car', 'cars')
    assert analysis.term_in('missed train', 'I MISSED  train'.replace('  ', ' ')) and analysis.term_in('room 4', 'in room 4.') and not analysis.term_in('room 4', 'room 42')
    assert analysis.term_in('图书馆', '我在图书馆里') and analysis.term_in('猫', '一只白猫') and not analysis.term_in('', 'text')
    assert analysis.words('café́ train. 2026 well-known') == ['café́', 'train', 'well', 'known']
    assert analysis.dream_terms([], 'Their teacher waited beside frozen trains, frozen again before the station.') == ['teacher', 'waited', 'beside', 'frozen', 'trains', 'station']
    assert analysis.dream_terms(['lake', 'lake', 'train'], 'ignored text') == ['lake', 'train']
    assert len(analysis.dream_terms([], ' '.join(f'word{chr(97 + n // 26)}{chr(97 + n % 26)}x' for n in range(80)))) == 50


def test_memory_days_and_window():
    utc = timezone.utc
    at = lambda day: int(datetime.fromisoformat(day).replace(tzinfo=utc).timestamp() * 1000)
    later = {'recorded_at': at('2026-10-05'), 'event_date': '2026-10-01', 'is_ongoing': 0, 'text': ''}
    upcoming = {'recorded_at': at('2026-10-01'), 'event_date': '2026-10-20', 'is_ongoing': 0, 'text': ''}
    direct = {'recorded_at': at('2026-10-12'), 'event_date': None, 'is_ongoing': 0, 'text': ''}
    assert analysis.memory_days(later, utc, None) == (date(2026, 10, 1), date(2026, 10, 1), False)
    assert analysis.memory_days(upcoming, utc, None) == (date(2026, 10, 1), date(2026, 10, 20), False)
    assert analysis.memory_days(direct, utc, None) == (date(2026, 10, 12), date(2026, 10, 12), True)
    assert analysis.memory_days(direct, utc, date(2026, 10, 9)) == (date(2026, 10, 3), date(2026, 10, 9), False)
    score = lambda memory, dream_day, terms=(): analysis.memory_score(memory, analysis.memory_days(memory, utc, None), date.fromisoformat(dream_day), list(terms))
    assert [score(later, day) for day in ('2026-10-01', '2026-10-31', '2026-11-01')] == [1, 1, 0]
    assert [score(direct, day) for day in ('2026-09-12', '2026-09-11', '2026-11-11', '2026-11-12')] == [1, 0, 1, 0]
    assert score(later | {'is_ongoing': 1}, '2027-06-01') == 1 and score(later | {'text': 'the train and the lake'}, '2027-06-01', ['train', 'lake']) == 4


async def test_context_selects_memories_by_terms_window_and_ongoing(client, clock, monkeypatch):
    headers, user, dream_id = await journal(client)
    await organized(user, dream_id)
    ids = {}
    for name, offset, fields in (('old_train', -40, {'text': 'Train strikes all month.', 'event_date': '2026-08-01'}), ('window', -5, {'text': 'Moved flats.', 'event_date': '2026-10-05'}),
                                 ('ongoing', -100, {'text': 'Studying for exams.', 'event_date': '2026-06-01', 'is_ongoing': True}), ('both', -2, {'text': 'Skated on the lake.', 'event_date': '2026-10-08'}),
                                 ('future', -1, {'text': 'Train trip planned.', 'event_date': '2026-10-30'}), ('unrelated', -60, {'text': 'Bought shoes.', 'event_date': '2026-08-11'}),
                                 ('closed', -3, {'text': 'Lake walk.', 'event_date': '2026-10-07', 'allow_analysis': False}), ('ongoing2', -50, {'text': 'Job hunting.', 'is_ongoing': True})):
        clock['ms'] = NOON + offset * DAY
        ids[name] = await note(client, headers, **fields)
    clock['ms'] = NOON
    chosen = [(source['label'], next(name for name, memory_id in ids.items() if memory_id == source['source_id'])) for source in await context(dream_id) if source['kind'] == 'memory']
    assert chosen == [('M1', 'ongoing2'), ('M2', 'ongoing'), ('M3', 'future'), ('M4', 'both')]
    assert [source['label'] for source in await context(dream_id, use_history=0)] == ['DESC']
    _, _, early = await journal(client, text='A frozen lake and a train.', headers=headers, dream_date='2026-09-20')
    early_names = {next(name for name, memory_id in ids.items() if memory_id == source['source_id']) for source in await context(early) if source['kind'] == 'memory'}
    assert early_names.isdisjoint({'both', 'future', 'window'}) and {'ongoing2', 'ongoing'} <= early_names
    monkeypatch.setattr(config, 'MAX_CONTEXT_MEMORIES', 20)
    roomy = {next(name for name, memory_id in ids.items() if memory_id == source['source_id']) for source in await context(dream_id) if source['kind'] == 'memory'}
    assert roomy == {'ongoing2', 'ongoing', 'future', 'both', 'old_train', 'window'}


async def test_context_selects_earlier_dreams_by_matching_terms(client, clock, monkeypatch):
    headers, user, dream_id = await journal(client)
    await organized(user, dream_id)
    earlier = {}
    for name, day, text in (('two_terms', '2026-10-01', 'A train crossed a frozen lake.'), ('tag_match', '2026-09-01', 'Night ride.'), ('one_term', '2026-10-02', 'Only a lake here.'),
                            ('after', '2026-10-11', 'Train by the lake again.'), ('closed', '2026-10-03', 'Train and lake, private.'), ('long', '2026-09-15', 'Train and lake. ' + 'x' * 2000)):
        _, _, earlier[name] = await journal(client, text=text, headers=headers, dream_date=day, permissions={'history': name != 'closed'})
    await organized(user, earlier['tag_match'], summary='Night train by the lake.', tags=(('object', 'train', 'ride'),))
    chosen = [source for source in await context(dream_id) if source['kind'] == 'dream']
    names = [next(name for name, value in earlier.items() if value == source['source_id']) for source in chosen]
    assert names == ['two_terms', 'long', 'tag_match'] and [source['label'] for source in chosen] == ['D1', 'D2', 'D3']
    long = next(source for source in chosen if source['source_id'] == earlier['long'])
    assert long['cut_to'] == 1500 and len(long['text']) == 1500 and chosen[0]['cut_to'] is None
    monkeypatch.setattr(config, 'MAX_CONTEXT_DREAMS', 20)
    assert {source['source_id'] for source in await context(dream_id) if source['kind'] == 'dream'} == {earlier['two_terms'], earlier['long'], earlier['tag_match']}


async def test_analyze_saves_checked_sections_and_sources(client, clock, gemini):
    headers, user, dream_id = await journal(client, mood='anxious')
    desc = await organized(user, dream_id)
    clock['ms'] = NOON - 2 * DAY
    memory_id = await note(client, headers, 'Exam deadline at the station office.', event_date='2026-10-08')
    _, _, earlier = await journal(client, text='A train stopped at a frozen lake.', headers=headers, dream_date='2026-09-30')
    clock['ms'] = NOON
    gemini.answers.append({'sections': [
        section('reflection_questions', 'What did missing it mean?\nWho waved?\nA third question.'),
        section('what_happened', 'You missed a train [DESC].'),
        section('waking_life_connections', 'The deadline may echo the rush.', ['M1', 'DREAM']),
        section('related_dreams', 'An earlier frozen lake.', ['D1']),
        section('emotional_movement', '   '),
        section('what_happened', 'A duplicate.'),
        section('themes_and_readings', 'Uncertain destinations.', ['DESC'])]})
    assert await tasks.run_once()
    assert (await analyze_task(dream_id))['status'] == 'completed'
    [output] = await stored(dream_id)
    content = output['content']
    assert [s['kind'] for s in content['sections']] == ['what_happened', 'waking_life_connections', 'themes_and_readings', 'related_dreams', 'reflection_questions']
    assert content['sections'][0] == {'kind': 'what_happened', 'text': 'You missed a train [DESC].', 'citations': ['DREAM', 'DESC']}
    assert content['sections'][-1]['text'] == 'What did missing it mean?\nWho waved?'
    assert (content['withheld'], content['removed_sources'], content['dream_date'], content['mood'], output['instruction_version'], output['status']) == (0, 0, '2026-10-10', 'anxious', 'analyze-1', 'current')
    rows = [tuple(row) for row in await db.rwdb.execute_fetchall('SELECT label,kind,source_id,source_revision,source_date,cut_to FROM sources WHERE output_id=? ORDER BY label', (output['id'],))]
    assert rows == [('D1', 'dream', earlier, 1, '2026-09-30', None), ('DESC', 'output', desc, 1, None, None), ('M1', 'memory', memory_id, 1, '2026-10-08', None)]
    call = gemini.calls[0]
    assert call['temperature'] is None and call['name'] == 'analysis'
    assert [line for line in call['content'].splitlines() if line.startswith('## ')] == ['## DREAM (2026-10-10)', '## DESC', '## M1 (2026-10-08)', '## D1 (2026-09-30)']
    assert 'Mood: anxious' in call['content'] and 'Train title' not in call['content'] and 'About 120 words.' in call['content']
    assert 'Labels that may be cited:\nDREAM, DESC, M1, D1' in call['content'] and 'waking_life_connections' in call['content'].split('Section kinds possible in this call:\n')[1]
    markers = re.findall(r'<<<ACCOUNT ([0-9a-f]{8})', call['content'])
    assert len(markers) == 2 and all(f'<<<ACCOUNT {marker}' in call['instruction'] for marker in markers) and not re.search(r'\[(?:DREAM|DESC|M\d|D\d)\]', call['content'])
    body = (await client.get(f'/v1/dreams/{dream_id}/analysis', headers=headers)).json()
    assert [entry['label'] for entry in body['analysis']['context']] == ['DREAM', 'D1', 'DESC', 'M1'] or [entry['label'] for entry in body['analysis']['context']] == ['DREAM', 'DESC', 'M1', 'D1']
    assert all(entry['available'] for entry in body['analysis']['context']) and body['task']['status'] == 'completed' and body['analysis']['removed_sources'] == 0
    assert (await client.get('/v1/dreams', headers=headers)).json()['items'][0]['status'] == 'ready'


async def test_impossible_kinds_are_dropped_and_missing_required_kinds_fail(client, clock, gemini):
    _, user, dream_id = await journal(client)
    await organized(user, dream_id)
    gemini.answers += [{'sections': [*BASE, section('waking_life_connections', 'No notes exist.', ['M1']), section('related_dreams', 'None.', ['D1'])]},
                       {'sections': [section('what_happened')]}, {'sections': []}]
    assert await tasks.run_once()
    [output] = await stored(dream_id)
    assert ([s['kind'] for s in output['content']['sections']], output['content']['withheld'], len(gemini.calls)) == (['what_happened', 'reflection_questions'], 0, 1)
    assert 'waking_life_connections' not in gemini.calls[0]['content'].split('Section kinds possible in this call:\n')[1].split('\n')[0]
    _, other_user, other = await journal(client)
    await organized(other_user, other)
    assert await tasks.run_once()
    assert ((await analyze_task(other))['status'], (await analyze_task(other))['error_code']) == ('waiting', 'invalid_output')
    clock['ms'] += 15000
    assert await tasks.run_once() and (await analyze_task(other))['error_code'] == 'invalid_output'


async def test_repair_replaces_failed_references_or_withholds(client, clock, gemini, monkeypatch):
    headers, user, dream_id = await journal(client)
    await organized(user, dream_id)
    await journal(client, text='A train at a frozen lake long ago.', headers=headers, dream_date='2026-09-01')
    first = {'sections': [*BASE, section('related_dreams', 'Like an older dream.', ['D7']), section('themes_and_readings', 'See [M2].', ['DREAM'])]}
    repaired = {'sections': [section('related_dreams', 'Like the earlier lake dream.', ['D1']), section('what_happened', 'Rewritten good section.'), section('themes_and_readings', 'Still [M3].', ['DREAM'])]}
    gemini.answers += [first, repaired]
    assert await tasks.run_once()
    [output] = await stored(dream_id)
    by_kind = {s['kind']: s for s in output['content']['sections']}
    assert by_kind['related_dreams']['citations'] == ['D1'] and by_kind['what_happened']['text'] == BASE[0]['text'] and 'themes_and_readings' not in by_kind
    assert output['content']['withheld'] == 1 and gemini.calls[1]['temperature'] == 0 and 'related_dreams: D7' in gemini.calls[1]['content'] and 'themes_and_readings: M2' in gemini.calls[1]['content']
    assert (await db.rwdb.execute_fetchall("SELECT count FROM usage WHERE user_id=?", (user,)))[0][0] == 2
    _, user, dream_id = await journal(client)
    await organized(user, dream_id)
    gemini.answers += [{'sections': [*BASE, section('emotional_movement', 'Rests on [NOTES].')]}, providers.ProviderError('provider_refused', False)]
    assert await tasks.run_once()
    [output] = await stored(dream_id)
    assert ([s['kind'] for s in output['content']['sections']], output['content']['withheld']) == (['what_happened', 'reflection_questions'], 1)
    monkeypatch.setitem(config.CAPS, 'text', 1)
    _, user, dream_id = await journal(client)
    await organized(user, dream_id)
    calls = len(gemini.calls)
    gemini.answers.append({'sections': [*BASE, section('threat_and_response', 'Cites [X1] and [D4].', ['D4'])]})
    assert await tasks.run_once()
    [output] = await stored(dream_id)
    assert output['content']['withheld'] == 1 and len(gemini.calls) == calls + 1


async def test_initial_analysis_is_skipped_after_a_refresh_and_late_changes_save_nothing(client, clock, gemini):
    headers, user, dream_id = await journal(client)
    await organized(user, dream_id)
    refresh = await client.post(f'/v1/dreams/{dream_id}/analysis/refresh', headers=headers, json={'refresh_id': str(uuid4())})
    assert refresh.status_code == 200 and refresh.json()['task']['type'] == 'analyze'
    await db.rwdb.execute("UPDATE tasks SET status='failed',error_code='network' WHERE dream_id=? AND type='analyze'", (dream_id,))
    created = await client.post(f'/v1/dreams/{dream_id}/analysis/refresh', headers=headers, json={'refresh_id': str(uuid4())})
    assert created.status_code == 202
    gemini.answers.append({'sections': BASE})
    assert await tasks.run_once()
    await db.rwdb.execute("UPDATE tasks SET status='waiting',attempts=0,error_code=NULL WHERE request_key=?", (f'analyze:{dream_id}:1:initial',))
    calls = len(gemini.calls)
    assert await tasks.run_once()
    assert ((await db.rwdb.execute_fetchall('SELECT status FROM tasks WHERE request_key=?', (f'analyze:{dream_id}:1:initial',)))[0][0], len(gemini.calls)) == ('completed', calls)
    headers, user, dream_id = await journal(client, mood='calm')
    await organized(user, dream_id)
    clock['ms'] -= DAY
    memory_id = await note(client, headers, 'Train strike.', event_date='2026-10-09')
    clock['ms'] += DAY
    changes = [lambda: client.put(f'/v1/memories/{memory_id}', headers=headers, json={'base_revision': 1, 'text': 'Train strike ended.'}),
               lambda: client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': 1, 'text': TEXT, 'dream_date': '2026-10-10', 'mood': 'sad'}),
               lambda: client.put('/v1/me', headers=headers, json={'use_history': False}),
               lambda: db.rwdb.execute('INSERT INTO discussion_corrections(id,user_id,dream_id,note,created_at) VALUES(?,?,?,?,1)', (str(uuid4()), user, dream_id, 'Not about school.'))]
    for change in changes:
        async def during_call(change=change):
            await change()
            return {'sections': BASE}
        gemini.answers.append(during_call)
        clock['ms'] += 300000
        assert await tasks.run_once()
        assert ((await analyze_task(dream_id))['status'], (await analyze_task(dream_id))['error_code']) == ('waiting', 'context_changed')
        await db.rwdb.execute("UPDATE tasks SET attempts=0 WHERE dream_id=? AND type='analyze'", (dream_id,))
    assert await stored(dream_id) == []
    async def edit_during_call():
        await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': 1, 'text': 'A new account.', 'dream_date': '2026-10-10', 'mood': 'sad'})
        return {'sections': BASE}
    gemini.answers.append(edit_during_call)
    clock['ms'] += 300000
    assert await tasks.run_once()
    assert (await db.rwdb.execute_fetchall('SELECT status FROM tasks WHERE request_key=?', (f'analyze:{dream_id}:1:initial',)))[0][0] == 'obsolete'


async def test_organize_outcomes_schedule_analysis(client, clock, monkeypatch):
    monkeypatch.setattr(tasks, 'handlers', {'organize': dreams.organize})
    answers = [{'summary': 'A train.', 'items': []}, providers.ProviderError('provider_refused', False)]
    async def complete_json(*args, **kwargs):
        answer = answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return msgspec.convert(answer, dreams.OrganizeAnswer)
    monkeypatch.setattr(providers, 'complete_json', complete_json)
    keys = []
    for _ in range(2):
        _, _, dream_id = await journal(client)
        assert await tasks.run_once()
        keys.append([row[0] for row in await db.rwdb.execute_fetchall("SELECT request_key FROM tasks WHERE dream_id=? AND type='analyze'", (dream_id,))])
    monkeypatch.setitem(config.CAPS, 'text', 0)
    capped_headers, _, capped = await journal(client)
    assert await tasks.run_once()
    for state in (False, True):
        await client.put(f'/v1/dreams/{capped}/permissions', headers=capped_headers, json={'visuals': state})
    assert [len(found) for found in keys] == [1, 1] and all(found[0].endswith(':initial') for found in keys)
    assert not await db.rwdb.execute_fetchall("SELECT 1 FROM tasks WHERE dream_id=? AND type='analyze'", (capped,))


async def test_refresh_route_and_read_route(client, clock, monkeypatch):
    headers, user, dream_id = await journal(client)
    url = f'/v1/dreams/{dream_id}/analysis'
    empty = (await client.get(url, headers=headers)).json()
    assert empty['analysis'] is None and (empty['task']['type'], empty['task']['status']) == ('organize', 'waiting')
    waiting = await client.post(f'{url}/refresh', headers=headers, json={'refresh_id': str(uuid4())})
    assert waiting.status_code == 200 and waiting.json()['task']['type'] == 'organize'
    await organized(user, dream_id)
    await db.rwdb.execute("UPDATE tasks SET status='completed' WHERE dream_id=?", (dream_id,))
    refresh_id = str(uuid4())
    first = await client.post(f'{url}/refresh', headers=headers, json={'refresh_id': refresh_id})
    assert first.status_code == 202 and first.json()['task']['status'] == 'waiting'
    await db.rwdb.execute("UPDATE tasks SET status='failed' WHERE id=?", (first.json()['task']['id'],))
    again = await client.post(f'{url}/refresh', headers=headers, json={'refresh_id': refresh_id})
    assert again.status_code == 200 and again.json()['task']['id'] == first.json()['task']['id']
    assert (await db.rwdb.execute_fetchall('SELECT request_key FROM tasks WHERE id=?', (first.json()['task']['id'],)))[0][0] == f'analyze:{dream_id}:1:{refresh_id}'
    monkeypatch.setitem(config.CAPS, 'text', 0)
    capped = await client.post(f'{url}/refresh', headers=headers, json={'refresh_id': str(uuid4())})
    assert capped.status_code == 429 and capped.json()['error'] == 'cap_reached'
    monkeypatch.setitem(config.CAPS, 'text', 200)
    assert (await client.get(url, headers=headers)).json()['task']['id'] == first.json()['task']['id']
    await client.put(f'/v1/dreams/{dream_id}/permissions', headers=headers, json={'analysis': False})
    off = await client.post(f'{url}/refresh', headers=headers, json={'refresh_id': str(uuid4())})
    assert off.status_code == 403 and off.json()['error'] == 'not_permitted'
    _, _, voice = await journal(client, text='', headers=headers, source='voice')
    assert (await client.post(f'/v1/dreams/{voice}/analysis/refresh', headers=headers, json={'refresh_id': str(uuid4())})).status_code == 409
    assert (await client.post(f'{url}/refresh', headers=credential(), json={'refresh_id': str(uuid4())})).status_code == 404
    assert (await client.post(f'{url}/refresh', headers=headers, json={'refresh_id': 'nope'})).status_code == 400
    assert (await client.get(url, headers=credential())).status_code == 404 and (await client.get(url)).status_code == 401


async def test_memory_exclusion_deletion_and_edit_invalidate_analyses(client, clock, gemini):
    headers, user, dream_id = await journal(client)
    await organized(user, dream_id)
    _, _, second = await journal(client, text='The train and the lake once more.', headers=headers, dream_date='2026-10-10')
    await organized(user, second)
    clock['ms'] -= DAY
    memory_id = await note(client, headers, 'A train strike at the lake.', event_date='2026-10-09')
    clock['ms'] += DAY
    reading = [*BASE, section('waking_life_connections', 'The strike may echo this.', ['M1'])]
    gemini.answers += [{'sections': reading}, {'sections': reading}]
    assert await tasks.run_once() and await tasks.run_once()
    url = f'/v1/dreams/{dream_id}/analysis'
    await client.put(f'/v1/memories/{memory_id}', headers=headers, json={'base_revision': 1, 'text': 'A train strike at the lake.', 'allow_analysis': False})
    excluded = (await client.get(url, headers=headers)).json()['analysis']
    assert excluded['status'] == 'outdated' and [s['kind'] for s in excluded['sections']] == ['what_happened', 'reflection_questions']
    assert 'M1' not in [entry['label'] for entry in excluded['context']] and excluded['removed_sources'] == 1
    assert len(await db.rwdb.execute_fetchall("SELECT 1 FROM sources WHERE kind='memory' AND source_id=?", (memory_id,))) == 2
    assert (await client.delete(f'/v1/memories/{memory_id}', headers=headers)).status_code == 204
    for target in (dream_id, second):
        deleted = (await client.get(f'/v1/dreams/{target}/analysis', headers=headers)).json()['analysis']
        assert (deleted['sections'], deleted['removed_sources'], deleted['status']) == ([], 1, 'outdated')
    assert not await db.rwdb.execute_fetchall("SELECT 1 FROM sources WHERE kind='memory'")
    _, user, third = await journal(client, headers=headers)
    await organized(user, third)
    clock['ms'] -= DAY
    edited = await note(client, headers, 'The lake froze over.', event_date='2026-10-09')
    clock['ms'] += DAY
    gemini.answers.append({'sections': reading})
    assert await tasks.run_once()
    await client.put(f'/v1/memories/{edited}', headers=headers, json={'base_revision': 1, 'text': 'The lake thawed.'})
    after_edit = (await client.get(f'/v1/dreams/{third}/analysis', headers=headers)).json()['analysis']
    assert after_edit['status'] == 'outdated' and len(after_edit['sections']) == 3
    assert [entry['available'] for entry in after_edit['context'] if entry['kind'] == 'memory'] == [False]


async def test_earlier_dream_exclusion_deletion_and_date_or_mood_changes(client, clock, gemini):
    headers, user, earlier = await journal(client, text='A train crossed the frozen lake.', dream_date='2026-10-01')
    await organized(user, earlier)
    _, _, dream_id = await journal(client, headers=headers)
    await organized(user, dream_id)
    gemini.answers += [{'sections': BASE}, {'sections': [*BASE, section('related_dreams', 'Like before.', ['D1'])]}]
    assert await tasks.run_once() and await tasks.run_once()
    url = f'/v1/dreams/{dream_id}/analysis'
    await client.put(f'/v1/dreams/{earlier}', headers=headers, json={'base_revision': 1, 'text': 'A train crossed the frozen lake.', 'dream_date': '2026-10-02', 'title': 'Train title'})
    assert (await client.get(url, headers=headers)).json()['analysis']['status'] == 'outdated'
    await client.put(f'/v1/dreams/{earlier}/permissions', headers=headers, json={'history': False})
    hidden = (await client.get(url, headers=headers)).json()['analysis']
    assert 'related_dreams' not in [s['kind'] for s in hidden['sections']] and hidden['removed_sources'] == 1
    await client.delete(f'/v1/dreams/{earlier}', headers=headers)
    gone = (await client.get(url, headers=headers)).json()['analysis']
    assert (gone['sections'], gone['removed_sources']) == ([], 1)
    _, user, own = await journal(client, headers=headers, mood='calm')
    await organized(user, own)
    gemini.answers.append({'sections': BASE})
    assert await tasks.run_once()
    await client.put(f'/v1/dreams/{own}', headers=headers, json={'base_revision': 1, 'text': TEXT, 'dream_date': '2026-10-10', 'title': 'Renamed', 'mood': 'calm'})
    assert (await client.get(f'/v1/dreams/{own}/analysis', headers=headers)).json()['analysis']['status'] == 'current'
    await client.put(f'/v1/dreams/{own}', headers=headers, json={'base_revision': 1, 'text': TEXT, 'dream_date': '2026-10-10', 'mood': 'sad'})
    assert (await client.get(f'/v1/dreams/{own}/analysis', headers=headers)).json()['analysis']['status'] == 'outdated'
    assert len(await stored(own)) == 1
