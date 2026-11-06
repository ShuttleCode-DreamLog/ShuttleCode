import json
import time
from types import SimpleNamespace
from uuid import uuid4

import httpx
import pytest
import config
import db
import providers
import records
import streams
from test_analysis import BASE, clock, gemini, journal, note, organized
from test_foundation import client, credential
from test_organize import endpoint


@pytest.fixture
def chat(monkeypatch):
    stand_in = SimpleNamespace(calls=[], replies=[])
    async def stream_text(instruction, messages):
        stand_in.calls.append({'instruction': instruction, 'messages': messages})
        reply = stand_in.replies.pop(0)
        for piece in reply if isinstance(reply, list) else [reply]:
            if isinstance(piece, Exception):
                raise piece
            yield piece
    monkeypatch.setattr(providers, 'stream_text', stream_text)
    streams.markers.clear()
    return stand_in


def events(response):
    found, name = [], None
    for line in response.text.splitlines():
        if line.startswith('event:'):
            name = line[6:].strip()
        elif line.startswith('data:'):
            found.append((name, json.loads(line[5:].strip())))
    return found


async def ask(client, headers, dream_id, text='Why was the lake frozen?', message_id=None):
    message_id = message_id or str(uuid4())
    response = await client.post(f'/v1/dreams/{dream_id}/conversation/messages', headers=headers, json={'message_id': message_id, 'text': text})
    return response, message_id


async def conversation(client, headers, dream_id):
    response = await client.get(f'/v1/dreams/{dream_id}/conversation', headers=headers)
    assert response.status_code == 200
    return response.json()['conversation']


async def analyzed(user, dream_id, memory_id=None):
    async with db.tx() as connection:
        revision = (await connection.execute_fetchall('SELECT revision FROM dreams WHERE id=?', (dream_id,)))[0][0]
        sources = [('M1', 'memory', memory_id, 1, None, None)] if memory_id else []
        return await records.save_output(connection, user, dream_id, 'analysis', revision, {'sections': BASE, 'withheld': 0, 'removed_sources': 0, 'dream_date': '2026-10-10', 'mood': None}, 'test', 'analyze-1', sources)


def test_control_line():
    read = lambda text, final=True: streams.read_control(text, 'OFFER:', final)
    assert read('OFFER: add_to_dream\nA detail.') == ('add_to_dream', 'A detail.')
    assert read('offer: None\nHello') == ('none', 'Hello')
    assert read('\nOFFER: none\nHello') == ('none', 'Hello')
    assert read('OFFER: none That sounds like a long day.') == ('none', 'That sounds like a long day.')
    assert read('Hello there') == (None, 'Hello there')
    assert read('Hel', False) == (None, 'Hel') and read('OFF', False) is None and read('OFFER: rem', False) is None
    assert read('OFFER: ' + 'x' * 50, False) == ('', 'x' * 50)


async def test_turn_saves_reply_offer_and_context(client, chat, clock):
    headers, user, dream_id = await journal(client)
    await organized(user, dream_id)
    memory_id = await note(client, headers, 'Skated on the lake.', event_date='2026-10-08')
    chat.replies.append(['OFF', 'ER: remember_in_profile\nThat skating ', 'day sounds vivid.'])
    response, message_id = await ask(client, headers, dream_id, 'I went skating last week.')
    assert response.status_code == 200 and response.headers['content-type'].startswith('text/event-stream')
    found = events(response)
    assert [name for name, _ in found] == ['start', 'delta', 'delta', 'done']
    assert found[0][1] == {'user_message_id': message_id, 'context_restarted': False}
    assert ''.join(data['text'] for name, data in found if name == 'delta') == 'That skating day sounds vivid.'
    done = found[-1][1]
    assert done['user_message']['id'] == message_id and done['message']['offer'] == 'remember_in_profile' and done['message']['reply_to'] == message_id
    assert [entry['label'] for entry in done['message']['context']] == ['DREAM', 'DESC', 'M1']
    call = chat.calls[0]
    assert call['messages'] == [{'role': 'user', 'content': 'I went skating last week.'}] and '<<<ACCOUNT' in call['instruction'] and 'OFFER: remember_in_profile' in call['instruction']
    stored = await conversation(client, headers, dream_id)
    assert [message['role'] for message in stored['messages']] == ['user', 'assistant'] and stored['messages'][1]['text'] == 'That skating day sounds vivid.'
    async with db.tx() as connection:
        assert (await connection.execute_fetchall('SELECT revision,text FROM dreams WHERE id=?', (dream_id,)))[0]['revision'] == 1
    # A repeat of a finished turn returns the saved reply with no call.
    response, _ = await ask(client, headers, dream_id, 'I went skating last week.', message_id)
    assert [name for name, _ in events(response)] == ['start', 'done'] and len(chat.calls) == 1


async def test_failures_keep_the_message_and_retry_saves_one_reply(client, chat):
    headers, _, dream_id = await journal(client)
    chat.replies.append(['OFFER: none\nPart', providers.ProviderError('network', True)])
    response, message_id = await ask(client, headers, dream_id)
    assert events(response)[-1] == ('error', events(response)[-1][1]) and events(response)[-1][1]['error'] == 'provider_error' and events(response)[-1][1]['request_id']
    chat.replies.append(providers.ProviderError('provider_refused', False))
    response, _ = await ask(client, headers, dream_id, message_id=message_id)
    assert events(response)[-1][1]['error'] == 'provider_refused'
    chat.replies.append('OFFER: none')
    response, _ = await ask(client, headers, dream_id, message_id=message_id)
    assert events(response)[-1][1]['error'] == 'provider_error'
    chat.replies.append('OFFER: none\nA reply.')
    response, _ = await ask(client, headers, dream_id, message_id=message_id)
    assert events(response)[-1][0] == 'done'
    messages = (await conversation(client, headers, dream_id))['messages']
    assert [(message['role'], message['state']) for message in messages] == [('user', 'ok'), ('assistant', 'ok')]
    response, _ = await ask(client, headers, dream_id, 'Different text', message_id)
    assert response.status_code == 409 and response.json()['error'] == 'invalid_state'


async def test_checks_before_the_stream(client, chat, monkeypatch):
    headers, user, dream_id = await journal(client)
    other = credential()
    assert (await ask(client, other, dream_id))[0].status_code == 404
    assert (await client.get(f'/v1/dreams/{dream_id}/conversation', headers=other)).status_code == 404
    assert (await client.post(f'/v1/dreams/{dream_id}/conversation/restart', headers=other)).status_code == 404
    assert (await ask(client, headers, dream_id, '  '))[0].status_code == 400
    assert (await ask(client, headers, dream_id, 'x' * 2001))[0].status_code == 413
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM conversations')
    streams.markers[dream_id] = (time.monotonic(), 'other')
    response, _ = await ask(client, headers, dream_id)
    assert response.status_code == 409 and response.json()['error'] == 'turn_in_progress'
    streams.markers.clear()
    monkeypatch.setitem(config.CAPS, 'text', 0)
    assert (await ask(client, headers, dream_id))[0].status_code == 429
    monkeypatch.setitem(config.CAPS, 'text', 200)
    assert (await client.put(f'/v1/dreams/{dream_id}/permissions', headers=headers, json={'discussion': False})).status_code == 200
    response, _ = await ask(client, headers, dream_id)
    assert response.status_code == 403 and response.json()['error'] == 'not_permitted'
    # Another user's message ID is not theirs to reuse.
    _, _, own = await journal(client, headers=other)
    chat.replies.append('OFFER: none\nHi.')
    _, taken = await ask(client, other, own)
    assert (await client.put(f'/v1/dreams/{dream_id}/permissions', headers=headers, json={'discussion': True})).status_code == 200
    assert (await ask(client, headers, dream_id, message_id=taken))[0].status_code == 404
    assert not streams.markers


async def test_thread_shape_and_restart(client, chat, monkeypatch):
    monkeypatch.setattr(config, 'MAX_THREAD_PAIRS', 2)
    headers, user, dream_id = await journal(client)
    await organized(user, dream_id)
    await analyzed(user, dream_id)
    for number in range(3):
        chat.replies.append(f'OFFER: none\nReply {number}.')
        assert events((await ask(client, headers, dream_id, f'Question {number}'))[0])[-1][0] == 'done'
    chat.replies.append(providers.ProviderError('network', True))
    await ask(client, headers, dream_id, 'Unanswered')
    chat.replies.append('OFFER: none\nReply 4.')
    await ask(client, headers, dream_id, 'Question 4')
    sent = chat.calls[-1]
    assert [message['content'] for message in sent['messages']] == ['Question 1', 'Reply 1.', 'Question 2', 'Reply 2.', 'Question 4']
    assert '## ANALYSIS' in sent['instruction']
    reply = (await conversation(client, headers, dream_id))['messages'][-1]
    assert [entry['label'] for entry in reply['context']] == ['DREAM', 'DESC', 'ANALYSIS']
    dream = (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream']
    assert (await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': dream['revision'], 'text': dream['text'], 'dream_date': dream['dream_date'], 'mood': 'sad'})).status_code == 200
    value = await conversation(client, headers, dream_id)
    assert value['analysis_withheld'] is True and all(message['state'] == 'stale' for message in value['messages'])
    chat.replies.append('OFFER: none\nAfresh.')
    found = events((await ask(client, headers, dream_id, 'Again'))[0])
    assert found[0][1]['context_restarted'] is True and [message['content'] for message in chat.calls[-1]['messages']] == ['Again']
    assert 'An analysis exists but is not available to you in this turn.' in chat.calls[-1]['instruction']
    usage = (await client.get('/v1/me', headers=headers)).json()['usage']
    response = await client.post(f'/v1/dreams/{dream_id}/conversation/restart', headers=headers)
    assert response.status_code == 200 and all(message['state'] == 'stale' for message in response.json()['conversation']['messages'])
    assert (await client.get('/v1/me', headers=headers)).json()['usage'] == usage
    _, _, empty = await journal(client, headers=headers)
    assert (await client.post(f'/v1/dreams/{empty}/conversation/restart', headers=headers)).status_code == 200
    assert not await db.rwdb.execute_fetchall('SELECT 1 FROM conversations WHERE dream_id=?', (empty,))


async def test_edits_and_source_changes_restart_the_context(client, chat, clock):
    headers, user, dream_id = await journal(client)
    await organized(user, dream_id)
    memory_id = await note(client, headers, 'Skated on the lake.', event_date='2026-10-08')
    chat.replies.append('OFFER: none\nOne.')
    await ask(client, headers, dream_id, 'First')
    states = lambda value: [message['state'] for message in value['messages']]
    dream = (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream']
    save = {'base_revision': dream['revision'], 'text': dream['text'], 'dream_date': dream['dream_date']}
    assert (await client.put(f'/v1/dreams/{dream_id}', headers=headers, json=save | {'title': 'New'})).status_code == 200
    assert states(await conversation(client, headers, dream_id)) == ['ok', 'ok']
    # The memory was supplied, so editing it restarts the discussion.
    memory = (await client.get(f'/v1/memories/{memory_id}', headers=headers)).json()['memory']
    assert (await client.put(f'/v1/memories/{memory_id}', headers=headers, json={'base_revision': memory['revision'], 'text': 'Skated twice.'})).status_code == 200
    assert states(await conversation(client, headers, dream_id)) == ['stale', 'stale']
    chat.replies.append('OFFER: none\nTwo.')
    await ask(client, headers, dream_id, 'Second')
    chat.replies.append('OFFER: none\nThree.')
    await ask(client, headers, dream_id, 'Third')
    # Deleting a memory removes every reply from the first that was given it, and leaves the user's own words stale.
    assert (await client.delete(f'/v1/memories/{memory_id}', headers=headers)).status_code == 204
    value = await conversation(client, headers, dream_id)
    assert [(message['role'], message['text']) for message in value['messages']] == [('user', 'First'), ('user', 'Second'), ('user', 'Third')] and set(states(value)) == {'stale'}
    chat.replies.append('OFFER: none\nFour.')
    await ask(client, headers, dream_id, 'Fourth')
    assert (await client.put(f'/v1/dreams/{dream_id}', headers=headers, json=save | {'mood': 'calm'})).status_code == 200
    assert set(states(await conversation(client, headers, dream_id))) == {'stale'}
    chat.replies.append('OFFER: none\nFive.')
    await ask(client, headers, dream_id, 'Fifth')
    dream = (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream']
    assert (await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': dream['revision'], 'text': dream['text'] + ' More.', 'dream_date': dream['dream_date']})).status_code == 200
    assert set(states(await conversation(client, headers, dream_id))) == {'stale'}


async def test_history_switch_and_indirect_sources(client, chat, clock):
    headers, user, dream_id = await journal(client)
    memory_id = await note(client, headers, 'Unrelated shoes.', event_date='2026-01-01')
    await analyzed(user, dream_id, memory_id)
    chat.replies.append('OFFER: none\nOne.')
    await ask(client, headers, dream_id)
    rows = await db.rwdb.execute_fetchall('SELECT label,indirect FROM sources WHERE message_id IS NOT NULL ORDER BY indirect')
    assert [(row['label'], row['indirect']) for row in rows] == [('ANALYSIS', 0), ('M1', 1)]
    assert [entry['label'] for entry in (await conversation(client, headers, dream_id))['messages'][1]['context']] == ['DREAM', 'ANALYSIS']
    _, _, plain = await journal(client, headers=headers, text='A short plain dream.')
    chat.replies.append('OFFER: none\nPlain.')
    await ask(client, headers, plain)
    assert (await client.put('/v1/me', headers=headers, json={'use_history': False})).status_code == 200
    assert {message['state'] for message in (await conversation(client, headers, dream_id))['messages']} == {'stale'}
    assert {message['state'] for message in (await conversation(client, headers, plain))['messages']} == {'ok'}
    assert (await conversation(client, headers, dream_id))['analysis_withheld'] is True
    chat.replies.append('OFFER: none\nTwo.')
    await ask(client, headers, dream_id, 'Again')
    assert '## ANALYSIS' not in chat.calls[-1]['instruction'] and '## M1' not in chat.calls[-1]['instruction']


async def test_change_during_a_turn_saves_nothing(client, chat, monkeypatch):
    headers, _, dream_id = await journal(client)
    async def changing(instruction, messages):
        yield 'OFFER: none\nHalf'
        async with db.tx() as connection:
            await connection.execute("UPDATE dreams SET mood='calm' WHERE id=?", (dream_id,))
        yield ' done.'
    monkeypatch.setattr(providers, 'stream_text', changing)
    response, _ = await ask(client, headers, dream_id)
    assert events(response)[-1][1]['error'] == 'context_changed'
    assert [message['role'] for message in (await conversation(client, headers, dream_id))['messages']] == ['user']


async def test_stream_adapter(endpoint):
    chunk = lambda content, finish=None: 'data: ' + json.dumps({'choices': [{'delta': {'content': content} if content else {}, 'finish_reason': finish}]}) + '\n\n'
    async def answer(request):
        return httpx.Response(200, text=chunk('OFFER: none\nHel') + ': ping\n\n' + chunk('lo.') + chunk(None, 'stop') + 'data: [DONE]\n\n')
    endpoint.install(answer)
    assert [piece async for piece in providers.stream_text('Instruction.', [{'role': 'user', 'content': 'Hi'}])] == ['OFFER: none\nHel', 'lo.']
    sent = json.loads(endpoint.seen[0].content)
    assert sent['stream'] is True and sent['messages'] == [{'role': 'system', 'content': 'Instruction.'}, {'role': 'user', 'content': 'Hi'}]
    for response, category in ((httpx.Response(200, text=chunk('Par') + chunk(None, 'content_filter')), 'provider_refused'),
                               (httpx.Response(400, text='{"error": "Request blocked by safety settings"}'), 'provider_refused'),
                               (httpx.Response(429, text='busy'), 'rate_limited'), (httpx.Response(200, text='data: {oops\n\n'), 'invalid_output')):
        async def failing(request, response=response):
            return response
        endpoint.install(failing)
        with pytest.raises(providers.ProviderError) as raised:
            async for _ in providers.stream_text('Instruction.', []):
                pass
        assert raised.value.category == category
