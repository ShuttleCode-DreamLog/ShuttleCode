import re
import secrets
import time
from uuid import uuid4

import msgspec
from sse_starlette import EventSourceResponse
import config
import db
import providers
import records
import tasks
from web import RequestError

# One entry per thread with a reply in progress: (start time, token). Turns in one thread are serialized by it (wiki 4.3.9).
markers = {}
ERROR_MESSAGES = {'provider_refused': 'The AI service declined to answer this message.', 'rate_limited': 'The AI service is busy. Try again in a minute.',
                  'provider_error': 'The reply could not be completed.', 'context_changed': 'The dream or its context changed while the reply was written.', **tasks.LIMIT_MESSAGES}


def release(thread_id, token):
    if markers.get(thread_id, (0, None))[1] == token:
        del markers[thread_id]


def read_control(held, word, final):
    # The start of a reply is held only while it could still be the control word and the one word after it (wiki 4.3.9, step 8).
    # Returns None while undecided, else (control value or None, reply text that follows).
    text = held.lstrip()
    if text[:len(word)].casefold() != word[:len(text)].casefold():
        return None, held
    if len(text) < len(word):
        return (None, held) if final else None
    after = text[len(word):].lstrip(' \t')
    value = re.match(r'\S+', after)
    if value and value.end() < len(after):
        rest = after[value.end():].lstrip(' \t')
        return value.group().casefold(), rest[1:] if rest.startswith('\n') else rest
    if final:
        return (value.group().casefold() if value else ''), ''
    return ('', after) if len(held) > config.CONTROL_HOLD_CHARS else None


def message_value(row, context=()):
    return {**{key: row[key] for key in ('id', 'seq', 'role', 'text', 'state', 'reply_to', 'offer', 'created_at')}, 'context': list(context)}


def event(name, value):
    return {'event': name, 'data': msgspec.json.encode(value).decode()}


async def run_turn(request, identity, thread_kind, thread_id, message_id, text, build_prompt, final_check, context_of, control_word=None):
    column = {'dream': 'dream_id', 'checkin': 'checkin_id'}[thread_kind]
    started = time.monotonic()
    if (marker := markers.get(thread_id)) and started - marker[0] < config.TURN_MARKER_SECONDS:
        raise RequestError(409, 'turn_in_progress', 'A reply in this conversation is still being written.')
    token = secrets.token_hex(8)
    markers[thread_id] = (started, token)
    handed = False
    try:
        async with db.tx() as connection:
            rows = await connection.execute_fetchall('SELECT * FROM messages WHERE id=?', (message_id,))
            stored = rows[0] if rows else None
            if stored is not None and stored['user_id'] != identity:
                raise RequestError(404, 'not_found', 'Message not found.')
            reply = next(iter(await connection.execute_fetchall('SELECT * FROM messages WHERE reply_to=?', (message_id,))), None)
            if stored is not None and (stored[column] != thread_id or stored['role'] != 'user' or stored['text'] != text):
                raise RequestError(409, 'invalid_state', 'This message ID was used for another message.')
            if stored is not None and reply is None and (await connection.execute_fetchall(f'SELECT id FROM messages WHERE {column}=? ORDER BY seq DESC LIMIT 1', (thread_id,)))[0]['id'] != message_id:
                raise RequestError(409, 'invalid_state', 'Only the latest message can be sent again.')
            if reply is None:
                # Sending a stored unanswered message again is the user sending that text now, so it is in use again.
                await connection.execute(f'''INSERT INTO messages(id,user_id,{column},seq,role,text,created_at) VALUES(?,?,?,(SELECT COALESCE(MAX(seq),0)+1 FROM messages WHERE {column}=?),'user',?,?)
                    ON CONFLICT(id) DO UPDATE SET state='ok' ''', (message_id, identity, thread_id, thread_id, text, config.now()))
        if reply is None and (reached := await records.is_cap_reached(identity, 'text')):
            raise RequestError(429, reached, tasks.LIMIT_MESSAGES[reached])
        prompt = None if reply is not None else await build_prompt()
        handed = True
    finally:
        if not handed:
            release(thread_id, token)

    def failed(code):
        return event('error', {'error': code, 'message': ERROR_MESSAGES[code], 'request_id': request.scope.get('request_id', '')})

    async def stream():
        try:
            yield event('start', {'user_message_id': message_id, 'context_restarted': bool(prompt and prompt['context_restarted'])})
            if reply is not None:
                user = (await db.rwdb.execute_fetchall('SELECT * FROM messages WHERE id=?', (message_id,)))[0]
                yield event('done', {'user_message': message_value(user), 'message': message_value(reply, await context_of(db.rwdb, reply))})
                return
            if reached := await records.charge(identity, 'text'):
                yield failed(reached)
                return
            held, pieces, control, decided = '', [], None, control_word is None
            try:
                async for piece in providers.stream_text(prompt['instruction'], prompt['messages']):
                    if not decided:
                        held += piece
                        if (result := read_control(held, control_word, False)) is None:
                            continue
                        (control, piece), decided = result, True
                    if piece:
                        pieces.append(piece)
                        yield event('delta', {'text': piece})
            except providers.ProviderError as error:
                yield failed(error.category if error.category in ('provider_refused', 'rate_limited') else 'provider_error')
                return
            if not decided:
                control, piece = read_control(held, control_word, True)
                if piece:
                    pieces.append(piece)
                    yield event('delta', {'text': piece})
            answer = ''.join(pieces).strip()
            if not answer:
                yield failed('provider_error')
                return
            async with db.tx() as connection:
                user = next(iter(await connection.execute_fetchall("SELECT * FROM messages WHERE id=? AND state='ok'", (message_id,))), None)
                extra = await final_check(connection, control) if user is not None else None
                if extra is not None:
                    reply_id = str(uuid4())
                    await connection.execute(f'''INSERT INTO messages(id,user_id,{column},seq,role,text,reply_to,dream_revision,offer,model,instruction_version,created_at)
                        VALUES(?,?,?,(SELECT MAX(seq)+1 FROM messages WHERE {column}=?),'assistant',?,?,?,?,?,?,?)''',
                        (reply_id, identity, thread_id, thread_id, answer, message_id, extra['dream_revision'], extra['offer'], prompt['model'], prompt['version'], config.now()))
                    await connection.executemany('INSERT INTO sources(id,user_id,message_id,label,kind,source_id,source_revision,source_date,cut_to,indirect) VALUES(?,?,?,?,?,?,?,?,?,?)',
                                                 [(str(uuid4()), identity, reply_id, source['label'], source['kind'], source['source_id'], source['source_revision'], source['source_date'], source['cut_to'], indirect)
                                                  for sources, indirect in ((prompt['sources'], 0), (extra['sources'], 1)) for source in sources])
                    saved = (await connection.execute_fetchall('SELECT * FROM messages WHERE id=?', (reply_id,)))[0]
                    done = {'user_message': message_value(user), 'message': message_value(saved, await context_of(connection, saved))}
            if extra is None:
                yield failed('context_changed')
                return
            yield event('done', done)
        finally:
            release(thread_id, token)

    return EventSourceResponse(stream())
