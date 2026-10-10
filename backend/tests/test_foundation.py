import asyncio
from datetime import datetime, timezone
from uuid import uuid4

import httpx
import pytest
import pytest_asyncio
import db
from main import app, application


@pytest_asyncio.fixture
async def client(tmp_path, monkeypatch):
    monkeypatch.setenv('DATA_DIR', str(tmp_path))
    monkeypatch.setenv('GEMINI_API_KEY', 'test-placeholder-not-used')
    async with application.router.lifespan_context(application):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='https://test') as client:
            yield client


def credential(identity=None):
    return {'Authorization': 'Bearer ' + (identity or str(uuid4()))}


@pytest.mark.parametrize('value', ['', 'Basic abc', 'Bearer nonsense', 'Bearer 00000000-0000-0000-0000-00000000000A', 'Bearer 00000000-0000-0000-0000-000000000000 extra'])
async def test_invalid_identity_does_not_create_user(client, value):
    for method in ('GET', 'PUT', 'DELETE'):
        response = await client.request(method, '/v1/me', headers={'Authorization': value}, json={'user_id': str(uuid4())})
        assert response.status_code == 401
        assert response.json()['error'] == 'invalid_user'
    assert not await db.rwdb.execute_fetchall('SELECT * FROM users')


async def test_settings_are_owned_and_partial_updates_preserve_fields(client):
    first, second = credential(), credential()
    initial = (await client.get('/v1/me', headers=first)).json()
    assert initial['use_history'] is True
    assert initial['reminder_weekday'] is None
    assert len(initial['limits']) == 12 and len(initial['usage']) == 3
    response = await client.put('/v1/me', headers=first, json={'timezone': 'America/Detroit', 'reminder_weekday': 4, 'use_history': False, 'user_id': second['Authorization'][7:]})
    assert response.status_code == 200
    assert response.json()['use_history'] is False
    other = (await client.get('/v1/me', headers=second)).json()
    assert other['use_history'] is True and other['timezone'] is None
    response = await client.put('/v1/me', headers=first, json={'timezone': 'Invalid/Timezone'})
    assert response.json()['timezone'] == 'America/Detroit'
    assert response.json()['reminder_weekday'] == 4
    response = await client.put('/v1/me', headers=first, json={'reminder_weekday': None})
    assert response.json()['reminder_weekday'] is None


@pytest.mark.parametrize('body', [{'reminder_weekday': 0}, {'reminder_weekday': 8}, {'reminder_weekday': True}, {'use_history': 1}, {'timezone': None}, []])
async def test_invalid_settings(client, body):
    assert (await client.put('/v1/me', headers=credential(), json=body)).status_code == 400


async def test_delete_cascades_and_removes_only_owned_files(client):
    first, second = credential(), credential()
    for headers in (first, second):
        await client.get('/v1/me', headers=headers)
    owner = first['Authorization'][7:]
    other = second['Authorization'][7:]
    dream, other_dream = str(uuid4()), str(uuid4())
    day = datetime.now(timezone.utc).date().isoformat()
    async with db.tx() as connection:
        for identity, dream_id in ((owner, dream), (other, other_dream)):
            await connection.execute('INSERT INTO dreams(id,user_id,dream_date,source,created_at,updated_at) VALUES(?,?,?,?,?,?)', (dream_id, identity, day, 'voice', 1, 1))
        await connection.execute("INSERT INTO usage VALUES(?,?,?,?)", (owner, day, 'text', 3))
        await connection.execute("INSERT INTO usage VALUES(?,?,?,?)", ('all', day, 'text', 3))
        await connection.execute("INSERT INTO tasks(id,user_id,type,request_key,dream_id,run_after,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)", (str(uuid4()), owner, 'transcribe', 'unique', dream, 1, 1, 1))
    audio = application.state.data_dir / 'audio'
    (audio / f'{dream}.aac').write_bytes(b'audio')
    (audio / f'{other_dream}.aac').write_bytes(b'audio')
    assert (await client.delete('/v1/me', headers=first)).status_code == 204
    for table in ('users', 'dreams', 'tasks', 'outputs', 'sources', 'usage', 'messages', 'tags', 'org_corrections', 'conversations', 'discussion_corrections', 'memories', 'checkins'):
        column = 'id' if table == 'users' else 'user_id'
        assert not await db.rwdb.execute_fetchall(f'SELECT * FROM {table} WHERE {column}=?', (owner,))
    assert not (audio / f'{dream}.aac').exists()
    assert (audio / f'{other_dream}.aac').exists()
    assert await db.rwdb.execute_fetchall("SELECT * FROM usage WHERE user_id='all'")
    assert (await client.delete('/v1/me', headers=first)).status_code == 204
    assert (await client.get('/v1/me', headers=second)).status_code == 200


async def test_transaction_rollback_on_cancellation(client):
    started = asyncio.Event()
    wait = asyncio.Event()
    async def write():
        async with db.tx() as connection:
            await connection.execute('INSERT INTO users(id,created_at) VALUES(?,?)', (str(uuid4()), 1))
            started.set()
            await wait.wait()
    task = asyncio.create_task(write())
    await started.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert not await db.rwdb.execute_fetchall('SELECT * FROM users')
    assert (await client.get('/v1/me', headers=credential())).status_code == 200


async def test_body_size_and_malformed_json(client):
    headers = credential()
    assert (await client.put('/v1/me', headers=headers, content='{')).status_code == 400
    assert (await client.put('/v1/me', headers=headers, content='x' * 262145)).status_code == 413


async def test_error_contract_and_known_user_read_is_write_free(client):
    headers = credential()
    await client.get('/v1/me', headers=headers)
    changes = db.rwdb.total_changes
    assert (await client.get('/v1/me', headers=headers)).status_code == 200
    assert changes == db.rwdb.total_changes
    for method, path, code, status in [('GET', '/v1/missing', 'not_found', 404), ('POST', '/v1/me', 'invalid_request', 405)]:
        response = await client.request(method, path, headers=headers)
        assert response.status_code == status
        body = response.json()
        assert body['error'] == code
        assert body['request_id'] == response.headers['x-request-id']
        assert len(body['request_id']) == 12
        assert body['current_revision'] is None


async def test_base_schema_accepts_all_records_and_deletes_together(client):
    import sqlite3
    headers = credential()
    await client.get('/v1/me', headers=headers)
    user = headers['Authorization'][7:]
    dream, output, checkin, memory, message, tag = [str(uuid4()) for _ in range(6)]
    statements = [
        ('INSERT INTO dreams(id,user_id,dream_date,source,created_at,updated_at) VALUES(?,?,?,?,?,?)', (dream,user,'2026-10-08','text',1,1)),
        ('INSERT INTO outputs(id,user_id,dream_id,type,dream_revision,content,model,instruction_version,created_at) VALUES(?,?,?,?,?,?,?,?,?)', (output,user,dream,'organization',1,'{}','test','test',1)),
        ('INSERT INTO checkins(id,user_id,week_start,opened_date,timezone,created_at,updated_at) VALUES(?,?,?,?,?,?,?)', (checkin,user,'2026-10-05','2026-10-08','America/Detroit',1,1)),
        ('INSERT INTO memories(id,user_id,text,recorded_at,event_precision,checkin_id,updated_at) VALUES(?,?,?,?,?,?,?)', (memory,user,'invented',1,'unknown',checkin,1)),
        ('INSERT INTO messages(id,user_id,dream_id,seq,role,text,created_at) VALUES(?,?,?,?,?,?,?)', (message,user,dream,1,'user','invented',1)),
        ('INSERT INTO tags(id,output_id,dream_id,user_id,category,text,excerpt) VALUES(?,?,?,?,?,?,?)', (tag,output,dream,user,'place','lake','lake')),
        ('INSERT INTO org_corrections VALUES(?,?,?,?,?,?)', (output,'place','lake','blue lake',user,1)),
        ('INSERT INTO conversations VALUES(?,?,?,?,?)', (dream,user,'reflect',1,1)),
        ('INSERT INTO discussion_corrections(id,user_id,dream_id,message_id,note,created_at) VALUES(?,?,?,?,?,?)', (str(uuid4()),user,dream,message,'invented correction',1)),
        ('INSERT INTO sources(id,user_id,output_id,label,kind,source_id,source_revision) VALUES(?,?,?,?,?,?,?)', (str(uuid4()),user,output,'M1','memory',memory,1)),
        ('INSERT INTO tasks(id,user_id,type,request_key,dream_id,run_after,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)', (str(uuid4()),user,'organize','base-schema',dream,1,1,1)),
        ('INSERT INTO usage VALUES(?,?,?,?)', (user,'2026-10-08','text',1)),
    ]
    async with db.tx() as connection:
        for sql, values in statements:
            await connection.execute(sql, values)
    tags = await db.rwdb.execute_fetchall('SELECT * FROM effective_tags')
    assert tags[0]['text'] == 'blue lake' and tags[0]['corrected'] == 1
    violations = [
        ('UPDATE users SET use_history=2 WHERE id=?', (user,)),
        ('UPDATE users SET reminder_weekday=0 WHERE id=?', (user,)),
        ('UPDATE dreams SET source=? WHERE id=?', ('invalid',dream)),
        ('UPDATE dreams SET allow_analysis=2 WHERE id=?', (dream,)),
        ('UPDATE tasks SET type=?', ('invalid',)),
        ('UPDATE tasks SET status=?', ('invalid',)),
        ('UPDATE outputs SET type=?', ('invalid',)),
        ('UPDATE outputs SET status=?', ('invalid',)),
        ('UPDATE sources SET kind=?', ('invalid',)),
        ('UPDATE sources SET message_id=?', (message,)),
        ('UPDATE usage SET kind=?', ('invalid',)),
        ('UPDATE messages SET role=?', ('invalid',)),
        ('UPDATE messages SET checkin_id=?', (checkin,)),
        ('UPDATE tags SET category=?', ('invalid',)),
        ('UPDATE tags SET feeling=?', ('invalid',)),
        ('UPDATE org_corrections SET category=?', ('invalid',)),
        ('UPDATE discussion_corrections SET note=?', ('',)),
        ('UPDATE memories SET event_precision=?', ('exact',)),
        ('UPDATE checkins SET status=?', ('invalid',)),
    ]
    for sql, values in violations:
        with pytest.raises(sqlite3.IntegrityError):
            async with db.tx() as connection:
                await connection.execute(sql, values)
    assert not await db.rwdb.execute_fetchall('PRAGMA foreign_key_check')
    assert (await client.delete('/v1/me', headers=headers)).status_code == 204
    for table in ('users','dreams','outputs','checkins','memories','messages','tags','org_corrections','conversations','discussion_corrections','sources','tasks','usage'):
        assert not await db.rwdb.execute_fetchall(f'SELECT * FROM {table}')


async def test_schema_mismatch_refuses_startup(tmp_path):
    import sqlite3
    path = tmp_path / 'old.sqlite'
    connection = sqlite3.connect(path)
    connection.execute('PRAGMA user_version=99')
    connection.close()
    with pytest.raises(RuntimeError, match='Schema version 99; expected 3'):
        await db.open_database(path)


async def test_cancel_waiting_transaction_does_not_rollback_other_writer(client):
    owner = str(uuid4())
    waiting = asyncio.Event()
    async def next_write():
        waiting.set()
        async with db.tx():
            raise AssertionError('Cancelled waiter acquired the lock')
    async with db.tx() as connection:
        await connection.execute('INSERT INTO users(id,created_at) VALUES(?,?)', (owner,1))
        task = asyncio.create_task(next_write())
        await waiting.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    assert await db.rwdb.execute_fetchall('SELECT * FROM users WHERE id=?', (owner,))


async def test_fault_response_and_logs_exclude_content(client, caplog):
    import logging
    from starlette.routing import Route
    from main import fault
    route = Route('/v1/faults', fault, methods=['POST'])
    application.router.routes.append(route)
    caplog.set_level(logging.DEBUG, logger='dreamlog')
    marker = 'private-journal-marker-never-log'
    try:
        response = await client.post('/v1/faults', json={'text': marker, 'where': 'route'})
        assert response.status_code == 500
        assert response.json()['error'] == 'internal'
        assert marker not in response.text
        assert marker not in caplog.text
        assert 'RuntimeError' in caplog.text and 'line=' in caplog.text
        assert response.headers['x-request-id'] in caplog.text
    finally:
        application.router.routes.remove(route)
