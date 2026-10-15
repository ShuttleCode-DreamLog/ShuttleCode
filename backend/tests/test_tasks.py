import asyncio
import logging
from uuid import uuid4

import pytest
from starlette.routing import Route
import config
import db
import providers
import records
import tasks
from main import application, fault
from test_foundation import client, credential

START = 1760000000000


@pytest.fixture
def clock(monkeypatch):
    now = {'ms': START}
    monkeypatch.setattr(config, 'now', lambda: now['ms'])
    return now


@pytest.fixture
def registry(monkeypatch):
    handlers = {}
    monkeypatch.setattr(tasks, 'handlers', handlers)
    monkeypatch.setattr(tasks, 'fault', None)
    return handlers


async def journal(client, headers=None):
    headers = headers or credential()
    dream_id = str(uuid4())
    response = await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': 0, 'text': 'An invented dream by a blue lake.', 'dream_date': '2026-10-08', 'source': 'text'})
    assert response.status_code == 201
    return headers, headers['Authorization'][7:], dream_id


async def queue(user, dream_id=None, task_type='organize', key=None, revision=1, run_after=None):
    key = key or f'{task_type}:{dream_id or user}:{uuid4()}'
    async with db.tx() as connection:
        await tasks.schedule(connection, task_type, key, user, dream_id, None, revision, run_after)
    return key


async def row(key):
    return (await db.rwdb.execute_fetchall('SELECT * FROM tasks WHERE request_key=?', (key,)))[0]


async def force(key, status, attempts=None, error=None):
    async with db.tx() as connection:
        await connection.execute('UPDATE tasks SET status=?,error_code=?,attempts=COALESCE(?,attempts),updated_at=? WHERE request_key=?', (status, error, attempts, config.now(), key))


async def finish(task):
    async with db.tx() as connection:
        if not await tasks.claimed(connection, task):
            return tasks.Obsolete()
        await tasks.complete(connection, task)
    return tasks.Done()


def scripted(*steps):
    remaining = list(steps)
    async def handler(task):
        handler.calls.append(task['attempts'])
        step = remaining.pop(0)
        if step == 'ok':
            return await finish(task)
        if isinstance(step, Exception):
            raise step
        return step
    handler.calls = []
    return handler


async def test_scheduling_is_idempotent_and_revives_only_obsolete(client, clock):
    _, user, dream_id = await journal(client)
    key = await queue(user, dream_id, key=f'organize:{dream_id}:1')
    await queue(user, dream_id, key=key)
    assert len(await db.rwdb.execute_fetchall('SELECT id FROM tasks WHERE request_key=?', (key,))) == 1
    await force(key, 'obsolete', attempts=2, error='network')
    clock['ms'] += 5000
    await queue(user, dream_id, key=key)
    revived = await row(key)
    assert (revived['status'], revived['attempts'], revived['error_code'], revived['run_after']) == ('waiting', 0, None, clock['ms'])
    await force(key, 'completed')
    await queue(user, dream_id, key=key)
    assert (await row(key))['status'] == 'completed'


async def test_temporary_failures_retry_with_delays_then_complete(client, clock, registry):
    _, user, dream_id = await journal(client)
    registry['organize'] = handler = scripted(providers.ProviderError('network', True), providers.ProviderError('provider_unavailable', True), 'ok')
    key = await queue(user, dream_id)
    assert await tasks.run_once()
    first = await row(key)
    assert (first['status'], first['attempts'], first['error_code'], first['run_after']) == ('waiting', 1, 'network', clock['ms'] + 15000)
    assert not await tasks.run_once()
    clock['ms'] += 15000
    assert await tasks.run_once()
    second = await row(key)
    assert (second['status'], second['attempts'], second['error_code'], second['run_after']) == ('waiting', 2, 'provider_unavailable', clock['ms'] + 60000)
    clock['ms'] += 60000
    assert await tasks.run_once()
    done = await row(key)
    assert (done['status'], done['attempts'], done['error_code']) == ('completed', 3, None)
    assert handler.calls == [1, 2, 3]


async def test_three_temporary_failures_end_failed(client, clock, registry):
    _, user, dream_id = await journal(client)
    registry['organize'] = scripted(*[providers.ProviderError('network', True)] * 3)
    key = await queue(user, dream_id)
    for delay in (0, 15000, 60000):
        clock['ms'] += delay
        assert await tasks.run_once()
    failed = await row(key)
    assert (failed['status'], failed['attempts'], failed['error_code']) == ('failed', 3, 'network')
    clock['ms'] += 10 ** 7
    assert not await tasks.run_once()


async def test_run_again_resets_attempts(client, clock, registry):
    _, user, dream_id = await journal(client)
    registry['organize'] = scripted(*[tasks.RunAgain(5)] * 5, 'ok')
    key = await queue(user, dream_id)
    for _ in range(5):
        assert await tasks.run_once()
        waiting = await row(key)
        assert (waiting['status'], waiting['attempts'], waiting['run_after']) == ('waiting', 0, clock['ms'] + 5000)
        clock['ms'] += 5000
    assert await tasks.run_once()
    assert ((await row(key))['status'], (await row(key))['attempts']) == ('completed', 1)
    network = providers.ProviderError('network', True)
    registry['analyze'] = scripted(network, network, tasks.RunAgain(1), network, network)
    other = await queue(user, dream_id, 'analyze')
    for _ in range(5):
        clock['ms'] += 60000
        assert await tasks.run_once()
    still = await row(other)
    assert (still['status'], still['attempts'], still['error_code']) == ('waiting', 2, 'network')


async def test_permanent_failures_and_obsolete_end_at_once(client, clock, registry):
    _, user, dream_id = await journal(client)
    cases = {'organize': (tasks.Failed('provider_refused', False), 'failed', 'provider_refused'),
             'analyze': (providers.ProviderError('provider_rejected', False), 'failed', 'provider_rejected'),
             'transcribe': (tasks.Obsolete(), 'obsolete', None)}
    keys = {}
    for task_type, (outcome, _, _) in cases.items():
        registry[task_type] = scripted(outcome)
        keys[task_type] = await queue(user, dream_id, task_type)
    for _ in cases:
        assert await tasks.run_once()
    for task_type, (_, status, code) in cases.items():
        ended = await row(keys[task_type])
        assert (ended['status'], ended['error_code'], ended['attempts']) == (status, code, 1)


async def test_claim_order_handler_gate_and_due_time(client, clock, registry):
    _, user, dream_id = await journal(client)
    registry['organize'] = scripted('ok', 'ok', 'ok', 'ok')
    first = await queue(user, dream_id)
    second = await queue(user, dream_id)
    earlier = await queue(user, dream_id, run_after=clock['ms'] - 1000)
    later = await queue(user, dream_id, run_after=clock['ms'] + 1000)
    unhandled = await queue(user, dream_id, 'analyze', run_after=clock['ms'] - 5000)
    order = []
    while await tasks.run_once():
        done = [key for key in (first, second, earlier, later) if (await row(key))['status'] == 'completed']
        order.extend(key for key in done if key not in order)
    assert order == [earlier, first, second]
    assert (await row(later))['status'] == 'waiting' and (await row(unhandled))['status'] == 'waiting'
    clock['ms'] += 1000
    assert await tasks.run_once() and (await row(later))['status'] == 'completed'
    assert not await tasks.run_once() and (await row(unhandled))['attempts'] == 0


async def test_restart_rule(client, clock):
    _, user, dream_id = await journal(client)
    keys = {name: await queue(user, dream_id, run_after=clock['ms'] - 1) for name in ('resumable', 'exhausted', 'config', 'network')}
    await force(keys['resumable'], 'running', attempts=1)
    await force(keys['exhausted'], 'running', attempts=3)
    await force(keys['config'], 'failed', attempts=3, error='provider_config')
    await force(keys['network'], 'failed', attempts=3, error='network')
    clock['ms'] += 1000
    await tasks.restart()
    resumed, exhausted, config_fault, network = [await row(keys[name]) for name in ('resumable', 'exhausted', 'config', 'network')]
    assert (resumed['status'], resumed['attempts'], resumed['run_after']) == ('waiting', 1, clock['ms'])
    assert (exhausted['status'], exhausted['error_code']) == ('failed', 'internal')
    assert (config_fault['status'], config_fault['attempts'], config_fault['error_code'], config_fault['run_after']) == ('waiting', 0, None, clock['ms'])
    assert (network['status'], network['error_code']) == ('failed', 'network')


async def test_row_left_running_is_released_before_the_next_claim(client, clock, registry, monkeypatch):
    _, user, dream_id = await journal(client)
    registry['organize'] = scripted(providers.ProviderError('network', True), 'ok')
    key = await queue(user, dream_id)
    settle = tasks.settle
    async def broken(task, outcome):
        raise RuntimeError('settle failed')
    monkeypatch.setattr(tasks, 'settle', broken)
    with pytest.raises(RuntimeError):
        await tasks.run_once()
    assert ((await row(key))['status'], (await row(key))['attempts']) == ('running', 1)
    monkeypatch.setattr(tasks, 'settle', settle)
    assert await tasks.run_once()
    assert ((await row(key))['status'], (await row(key))['attempts']) == ('completed', 2)
    stuck = await queue(user, dream_id)
    await force(stuck, 'running', attempts=3)
    assert not await tasks.run_once()
    assert ((await row(stuck))['status'], (await row(stuck))['error_code']) == ('failed', 'internal')


async def test_unexpected_handler_error_is_logged_without_its_message(client, clock, registry, caplog):
    caplog.set_level(logging.INFO, logger='dreamlog')
    _, user, dream_id = await journal(client)
    marker = 'private-dream-marker-never-log'
    registry['organize'] = scripted(RuntimeError(marker))
    key = await queue(user, dream_id)
    assert await tasks.run_once()
    task = await row(key)
    assert (task['status'], task['error_code']) == ('waiting', 'internal')
    assert 'RuntimeError' in caplog.text and f"task_id={task['id']}" in caplog.text and 'status=waiting error=internal' in caplog.text
    assert marker not in caplog.text


async def test_fault_route_task_form_fails_the_next_task_only(client, clock, registry, caplog):
    caplog.set_level(logging.INFO, logger='dreamlog')
    headers, user, dream_id = await journal(client)
    route = Route('/v1/faults', fault, methods=['POST'])
    application.router.routes.append(route)
    marker = 'private-fault-marker-never-log'
    try:
        response = await client.post('/v1/faults', headers=headers, json={'text': marker, 'where': 'task'})
        assert response.status_code == 200 and response.json() == {}
        registry['organize'] = handler = scripted('ok')
        key = await queue(user, dream_id)
        assert await tasks.run_once()
        assert (await row(key))['error_code'] == 'internal' and handler.calls == []
        clock['ms'] += 15000
        assert await tasks.run_once() and (await row(key))['status'] == 'completed'
        assert marker not in caplog.text
    finally:
        application.router.routes.remove(route)


async def test_charge_cap_ceiling_day_change_and_deleted_journal(client, clock, monkeypatch):
    monkeypatch.setitem(config.CAPS, 'text', 2)
    headers, user, _ = await journal(client)
    assert [await records.charge(user, 'text') for _ in range(3)] == [None, None, 'cap_reached']
    counters = {r['user_id']: r['count'] for r in await db.rwdb.execute_fetchall('SELECT user_id,count FROM usage')}
    assert counters == {user: 2, 'all': 2}
    me = (await client.get('/v1/me', headers=headers)).json()
    assert me['usage'][0] == {'kind': 'text', 'used': 2, 'cap': 2}
    monkeypatch.setitem(config.CAPS, 'text', 50)
    monkeypatch.setitem(config.CEILINGS, 'text', 2)
    _, other, _ = await journal(client)
    assert await records.charge(other, 'text') == 'ceiling_reached'
    assert await records.is_cap_reached(other, 'text') == 'ceiling_reached'
    assert not await db.rwdb.execute_fetchall('SELECT * FROM usage WHERE user_id=?', (other,))
    assert await records.charge(other, 'image') is None
    clock['ms'] += 24 * 3600 * 1000
    assert await records.charge(other, 'text') is None
    assert (await client.delete('/v1/me', headers=headers)).status_code == 204
    assert await records.charge(user, 'text') is None
    assert not await db.rwdb.execute_fetchall('SELECT * FROM usage WHERE user_id=?', (user,))
    day = records.utc_day()
    assert (await db.rwdb.execute_fetchall("SELECT count FROM usage WHERE user_id='all' AND day=? AND kind='text'", (day,)))[0][0] == 2


async def test_task_at_a_limit_ends_failed_without_retrying(client, clock, registry, monkeypatch):
    async def charged(task):
        reached = await records.charge(task['user_id'], 'text')
        return tasks.Failed(reached, False) if reached else await finish(task)
    registry['organize'] = charged
    _, user, dream_id = await journal(client)
    monkeypatch.setitem(config.CAPS, 'text', 1)
    assert await records.charge(user, 'text') is None
    capped = await queue(user, dream_id)
    assert await tasks.run_once()
    assert ((await row(capped))['status'], (await row(capped))['error_code'], (await row(capped))['attempts']) == ('failed', 'cap_reached', 1)
    monkeypatch.setitem(config.CAPS, 'text', 50)
    monkeypatch.setitem(config.CEILINGS, 'text', 1)
    _, other, other_dream = await journal(client)
    ceiling = await queue(other, other_dream)
    assert await tasks.run_once() and ((await row(ceiling))['status'], (await row(ceiling))['error_code']) == ('failed', 'ceiling_reached')
    assert len(await db.rwdb.execute_fetchall('SELECT id FROM tasks')) == 2


async def test_rate_limits_and_set_up_faults_use_long_delays_without_blocking(client, clock, registry):
    _, user, dream_id = await journal(client)
    registry['organize'] = scripted(*[providers.ProviderError('rate_limited', True)] * 3, *[providers.ProviderError('provider_config', True)] * 3)
    registry['analyze'] = scripted('ok')
    limited = await queue(user, dream_id)
    assert await tasks.run_once()
    assert (await row(limited))['run_after'] == clock['ms'] + 60000
    other = await queue(user, dream_id, 'analyze')
    assert await tasks.run_once() and (await row(other))['status'] == 'completed'
    clock['ms'] += 60000
    assert await tasks.run_once() and (await row(limited))['run_after'] == clock['ms'] + 300000
    clock['ms'] += 300000
    assert await tasks.run_once()
    assert ((await row(limited))['status'], (await row(limited))['error_code'], (await row(limited))['attempts']) == ('failed', 'rate_limited', 3)
    misconfigured = await queue(user, dream_id)
    for delay in (0, 60000, 300000):
        clock['ms'] += delay
        assert await tasks.run_once()
    assert ((await row(misconfigured))['status'], (await row(misconfigured))['error_code']) == ('failed', 'provider_config')
    await tasks.restart()
    assert ((await row(misconfigured))['status'], (await row(misconfigured))['attempts']) == ('waiting', 0)
    assert (await row(limited))['status'] == 'failed'


async def test_worker_loop_survives_errors_and_wakes_with_or_without_the_event(client, registry, monkeypatch, caplog):
    caplog.set_level(logging.INFO, logger='dreamlog')
    monkeypatch.setattr(config, 'WORKER_MAX_WAIT_SECONDS', 0.05)
    registry['organize'] = scripted('ok', 'ok')
    claim = tasks.claim
    failures = []
    async def flaky():
        if not failures:
            failures.append(1)
            raise RuntimeError('claim failed once')
        return await claim()
    monkeypatch.setattr(tasks, 'claim', flaky)
    _, user, dream_id = await journal(client)
    silent = await queue(user, dream_id)
    loop = asyncio.create_task(tasks.worker())
    try:
        for _ in range(100):
            if (await row(silent))['status'] == 'completed':
                break
            await asyncio.sleep(0.02)
        assert (await row(silent))['status'] == 'completed'
        assert 'error=RuntimeError' in caplog.text and not loop.done()
        monkeypatch.setattr(config, 'WORKER_MAX_WAIT_SECONDS', 30)
        await asyncio.sleep(0.1)
        woken = await queue(user, dream_id)
        tasks.wake.set()
        for _ in range(50):
            if (await row(woken))['status'] == 'completed':
                break
            await asyncio.sleep(0.02)
        assert (await row(woken))['status'] == 'completed'
    finally:
        loop.cancel()
        with pytest.raises(asyncio.CancelledError):
            await loop


async def test_late_deletion_or_cancellation_is_left_alone(client, clock, registry):
    _, user, dream_id = await journal(client)
    async def delete_during_call(task):
        async with db.tx() as connection:
            await connection.execute('DELETE FROM dreams WHERE id=?', (task['dream_id'],))
        return tasks.Failed('network', True)
    registry['organize'] = delete_during_call
    gone = await queue(user, dream_id)
    assert await tasks.run_once()
    assert not await db.rwdb.execute_fetchall('SELECT id FROM tasks WHERE request_key=?', (gone,))
    _, user, dream_id = await journal(client)
    async def cancel_during_call(task):
        async with db.tx() as connection:
            await connection.execute("UPDATE tasks SET status='canceled' WHERE id=?", (task['id'],))
        return await finish(task) if task['type'] == 'analyze' else tasks.Failed('network', True)
    registry['organize'] = registry['analyze'] = cancel_during_call
    canceled = [await queue(user, dream_id, task_type) for task_type in ('organize', 'analyze')]
    assert await tasks.run_once() and await tasks.run_once()
    assert [(await row(key))['status'] for key in canceled] == ['canceled', 'canceled']


async def test_retry_route(client, clock, monkeypatch):
    headers, user, dream_id = await journal(client)
    failed = await queue(user, dream_id)
    await force(failed, 'failed', attempts=3, error='network')
    task_id = (await row(failed))['id']
    clock['ms'] += 1000
    for _ in range(2):
        response = await client.post(f'/v1/tasks/{task_id}/retry', headers=headers)
        assert response.status_code == 200
        assert response.json()['task'] == {'id': task_id, 'type': 'organize', 'status': 'waiting', 'error_code': None, 'dream_id': dream_id, 'subject_id': None, 'source_revision': 1, 'updated_at': clock['ms']}
    retried = await row(failed)
    assert (retried['attempts'], retried['run_after']) == (0, clock['ms'])
    assert len(await db.rwdb.execute_fetchall('SELECT id FROM tasks')) == 1
    for status in ('completed', 'canceled', 'obsolete'):
        await force(failed, status)
        response = await client.post(f'/v1/tasks/{task_id}/retry', headers=headers)
        assert response.status_code == 409 and response.json()['error'] == 'invalid_state'
    other = credential()
    assert (await client.post(f'/v1/tasks/{task_id}/retry', headers=other)).status_code == 404
    assert (await client.post(f'/v1/tasks/{uuid4()}/retry', headers=headers)).status_code == 404
    assert (await client.post(f'/v1/tasks/{task_id}/retry')).status_code == 401
    assert (await client.post('/v1/tasks/not-a-uuid/retry', headers=headers)).status_code == 400
    assert (await client.get(f'/v1/tasks/{task_id}/retry', headers=headers)).status_code == 405
    await force(failed, 'failed', error='cap_reached')
    monkeypatch.setitem(config.CAPS, 'text', 1)
    await records.charge(user, 'text')
    capped = await client.post(f'/v1/tasks/{task_id}/retry', headers=headers)
    assert capped.status_code == 429 and capped.json()['error'] == 'cap_reached'
    assert (await row(failed))['status'] == 'failed'
    monkeypatch.setitem(config.CAPS, 'text', 50)
    monkeypatch.setitem(config.CEILINGS, 'text', 1)
    assert (await client.post(f'/v1/tasks/{task_id}/retry', headers=headers)).json()['error'] == 'ceiling_reached'
    monkeypatch.setitem(config.CEILINGS, 'text', 50)
    monkeypatch.setitem(config.CAPS, 'image', 0)
    image = await queue(user, dream_id, 'generate_image')
    await force(image, 'failed', error='network')
    assert (await client.post(f"/v1/tasks/{(await row(image))['id']}/retry", headers=headers)).json()['error'] == 'cap_reached'
    assert (await client.post(f'/v1/tasks/{task_id}/retry', headers=headers)).status_code == 200


async def test_dream_tasks_and_journal_status(client, clock):
    headers, user, dream_id = await journal(client)
    async def view():
        dream = (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream']
        items = (await client.get('/v1/dreams', headers=headers)).json()['items']
        found = (await client.post('/v1/dreams/search', headers=headers, json={'query': 'invented'})).json()['items']
        assert items[0]['status'] == found[0]['status']
        return {task['type']: (task['status'], task['error_code']) for task in dream['tasks']}, items[0]['status']
    assert await view() == ({}, 'ready')
    organize = await queue(user, dream_id, key=f'organize:{dream_id}:1')
    dream = (await client.get(f'/v1/dreams/{dream_id}', headers=headers)).json()['dream']
    assert set(dream['tasks'][0]) == {'id', 'type', 'status', 'error_code', 'dream_id', 'subject_id', 'source_revision', 'updated_at'}
    assert await view() == ({'organize': ('waiting', None)}, 'processing')
    clock['ms'] += 1000
    await force(organize, 'failed', error='network')
    assert await view() == ({'organize': ('failed', 'network')}, 'attention')
    await force(organize, 'failed', error='provider_refused')
    assert await view() == ({'organize': ('failed', 'provider_refused')}, 'ready')
    transcribe = await queue(user, dream_id, 'transcribe', key=f'transcribe:{dream_id}', revision=None)
    await force(transcribe, 'failed', error='provider_refused')
    assert (await view())[1] == 'attention'
    await force(transcribe, 'completed')
    image = await queue(user, dream_id, 'generate_image', revision=1)
    await force(image, 'failed', error='network')
    assert await view() == ({'organize': ('failed', 'provider_refused'), 'transcribe': ('completed', None)}, 'ready')
    edited = await client.put(f'/v1/dreams/{dream_id}', headers=headers, json={'base_revision': 1, 'text': 'An edited invented dream.', 'dream_date': '2026-10-08'})
    assert edited.json()['dream']['revision'] == 2 and edited.json()['dream']['tasks'] == [t for t in edited.json()['dream']['tasks'] if t['type'] == 'transcribe']
    initial = await queue(user, dream_id, 'analyze', key=f'analyze:{dream_id}:2:initial', revision=2)
    await force(initial, 'completed')
    clock['ms'] += 1000
    refresh = await queue(user, dream_id, 'analyze', key=f'analyze:{dream_id}:2:{uuid4()}', revision=2)
    await force(refresh, 'failed', error='network')
    assert await view() == ({'transcribe': ('completed', None), 'analyze': ('failed', 'network')}, 'attention')
    permissions = await client.put(f'/v1/dreams/{dream_id}/permissions', headers=headers, json={'visuals': False})
    assert {task['type'] for task in permissions.json()['dream']['tasks']} == {'transcribe', 'analyze'}
    other_headers, _, _ = await journal(client)
    assert (await client.get('/v1/dreams', headers=other_headers)).json()['items'][0]['status'] == 'ready'
