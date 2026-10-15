import asyncio
import logging
import time
import traceback
from typing import NamedTuple
from uuid import uuid4

import config
import db
import providers
import records
from web import RequestError, check_id, json_response, resolve_user

logger = logging.getLogger("dreamlog")
# Component modules add their handlers here when imported; a type without a handler is never claimed (wiki 4.1, rule 6).
handlers = {}
wake = asyncio.Event()
fault = None
KINDS = {"generate_image": "image", "generate_video": "video"}
LIMIT_MESSAGES = {"cap_reached": "Today's limit for this kind of generation is used up.", "ceiling_reached": "DreamLog has reached today's limit for everyone."}


class Done:
    pass


class Obsolete:
    pass


class Failed(NamedTuple):
    code: str
    temporary: bool


class RunAgain(NamedTuple):
    seconds: float


def task_value(row):
    return {key: row[key] for key in ("id", "type", "status", "error_code", "dream_id", "subject_id", "source_revision", "updated_at")}


async def schedule(connection, task_type, request_key, identity, dream_id=None, subject_id=None, source_revision=None, run_after=None):
    timestamp = config.now()
    await connection.execute("""INSERT INTO tasks(id,user_id,type,request_key,dream_id,subject_id,source_revision,run_after,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(request_key) DO UPDATE SET status='waiting',attempts=0,error_code=NULL,run_after=excluded.run_after,updated_at=excluded.updated_at WHERE tasks.status='obsolete'""",
        (str(uuid4()), identity, task_type, request_key, dream_id, subject_id, source_revision, timestamp if run_after is None else run_after, timestamp, timestamp))


async def claimed(connection, task):
    rows = await connection.execute_fetchall("SELECT status FROM tasks WHERE id=?", (task["id"],))
    return bool(rows) and rows[0]["status"] == "running"


async def complete(connection, task):
    await connection.execute("UPDATE tasks SET status='completed',error_code=NULL,updated_at=? WHERE id=? AND status='running'", (config.now(), task["id"]))


async def release(connection, timestamp):
    # One task runs at a time, so a row still running here belongs to no handler: a restart or an error outside a handler left it.
    await connection.execute("UPDATE tasks SET status='waiting',run_after=?,updated_at=? WHERE status='running' AND attempts<?", (timestamp, timestamp, config.MAX_ATTEMPTS))
    await connection.execute("UPDATE tasks SET status='failed',error_code='internal',updated_at=? WHERE status='running'", (timestamp,))


async def restart():
    async with db.tx() as connection:
        timestamp = config.now()
        stuck = await connection.execute_fetchall("SELECT dream_id FROM tasks WHERE status='running' AND attempts>=? AND type IN ('transcribe','organize') AND dream_id IS NOT NULL", (config.MAX_ATTEMPTS,))
        await release(connection, timestamp)
        for row in stuck:
            await records.schedule_processing(connection, row["dream_id"])
        await connection.execute("UPDATE tasks SET status='waiting',attempts=0,error_code=NULL,run_after=?,updated_at=? WHERE status='failed' AND error_code='provider_config'", (timestamp, timestamp))


async def claim():
    async with db.tx() as connection:
        timestamp = config.now()
        await release(connection, timestamp)
        types = list(handlers)
        rows = await connection.execute_fetchall(f"SELECT id FROM tasks WHERE status='waiting' AND run_after<=? AND type IN ({','.join('?' * len(types))}) ORDER BY run_after,created_at,rowid LIMIT 1", (timestamp, *types)) if types else []
        if not rows:
            return None
        await connection.execute("UPDATE tasks SET status='running',attempts=attempts+1,updated_at=? WHERE id=?", (timestamp, rows[0]["id"]))
        return (await connection.execute_fetchall("SELECT * FROM tasks WHERE id=?", (rows[0]["id"],)))[0]


async def settle(task, outcome):
    async with db.tx() as connection:
        timestamp = config.now()
        # Every change requires the row to be running still, so a task canceled or deleted during the AI call stays as it is.
        match outcome:
            case Done():
                pass
            case Obsolete():
                await connection.execute("UPDATE tasks SET status='obsolete',updated_at=? WHERE id=? AND status='running'", (timestamp, task["id"]))
            case Failed(code, True) if task["attempts"] < config.MAX_ATTEMPTS:
                delays = config.RATE_LIMIT_DELAYS if code in ("rate_limited", "provider_config") else config.RETRY_DELAYS
                await connection.execute("UPDATE tasks SET status='waiting',error_code=?,run_after=?,updated_at=? WHERE id=? AND status='running'", (code, timestamp + delays[task["attempts"] - 1] * 1000, timestamp, task["id"]))
            case Failed(code, _):
                cursor = await connection.execute("UPDATE tasks SET status='failed',error_code=?,updated_at=? WHERE id=? AND status='running'", (code, timestamp, task["id"]))
                # A failed transcript or summary must not hold back what can proceed without it; a reached limit holds everything back (wiki 4.3.3).
                if cursor.rowcount and task["type"] in ("transcribe", "organize") and code not in ("cap_reached", "ceiling_reached") and task["dream_id"]:
                    await records.schedule_processing(connection, task["dream_id"])
            case RunAgain(seconds):
                await connection.execute("UPDATE tasks SET status='waiting',attempts=0,error_code=NULL,run_after=?,updated_at=? WHERE id=? AND status='running'", (timestamp + int(seconds * 1000), timestamp, task["id"]))


def log_error(task_id, error):
    location = traceback.extract_tb(error.__traceback__)[-1]
    logger.error("task_id=%s error=%s file=%s line=%s", task_id, type(error).__name__, location.filename, location.lineno)


async def run_once():
    global fault
    task = await claim()
    if task is None:
        return False
    started = time.monotonic()
    try:
        if fault is not None:
            text, fault = fault, None
            raise RuntimeError(text)
        outcome = await handlers[task["type"]](task)
    except providers.ProviderError as error:
        outcome = Failed(error.category, error.temporary)
    except Exception as error:
        log_error(task["id"], error)
        outcome = Failed("internal", True)
    await settle(task, outcome)
    rows = await db.rwdb.execute_fetchall("SELECT status,error_code FROM tasks WHERE id=?", (task["id"],))
    status, code = (rows[0]["status"], rows[0]["error_code"]) if rows else ("deleted", None)
    logger.info("task_id=%s type=%s attempt=%s status=%s error=%s duration_ms=%d", task["id"], task["type"], task["attempts"], status, code, (time.monotonic() - started) * 1000)
    return True


async def next_wait():
    types = list(handlers)
    rows = await db.rwdb.execute_fetchall(f"SELECT MIN(run_after) FROM tasks WHERE status='waiting' AND type IN ({','.join('?' * len(types))})", types) if types else [(None,)]
    return config.WORKER_MAX_WAIT_SECONDS if rows[0][0] is None else max(0, min(config.WORKER_MAX_WAIT_SECONDS, (rows[0][0] - config.now()) / 1000))


async def worker():
    while True:
        # Clearing before the round means a task scheduled during it still wakes the next wait.
        wake.clear()
        try:
            if await run_once():
                continue
            timeout = await next_wait()
        except Exception as error:
            log_error(None, error)
            timeout = config.WORKER_MAX_WAIT_SECONDS
        try:
            await asyncio.wait_for(wake.wait(), timeout)
        except TimeoutError:
            pass


async def retry_task(request):
    identity = await resolve_user(request)
    task_id = check_id(request.path_params["task_id"])
    async with db.tx() as connection:
        rows = await connection.execute_fetchall("SELECT * FROM tasks WHERE id=? AND user_id=?", (task_id, identity))
        if not rows:
            raise RequestError(404, "not_found", "Task not found.")
        if rows[0]["status"] in ("completed", "canceled", "obsolete"):
            raise RequestError(409, "invalid_state", "This task cannot be retried.")
        if rows[0]["status"] == "failed":
            reached = await records.limit_reached(connection, identity, KINDS.get(rows[0]["type"], "text"), records.utc_day())
            if reached:
                raise RequestError(429, reached, LIMIT_MESSAGES[reached])
            timestamp = config.now()
            await connection.execute("UPDATE tasks SET status='waiting',attempts=0,error_code=NULL,run_after=?,updated_at=? WHERE id=?", (timestamp, timestamp, task_id))
        task = (await connection.execute_fetchall("SELECT * FROM tasks WHERE id=?", (task_id,)))[0]
    wake.set()
    return json_response({"task": task_value(task)})


async def dream_tasks(identity, dream_id, revision):
    rows = await db.rwdb.execute_fetchall("SELECT * FROM tasks WHERE user_id=? AND dream_id=? AND type NOT IN ('generate_image','generate_video') AND (type='transcribe' OR source_revision=?) ORDER BY updated_at,created_at,rowid", (identity, dream_id, revision))
    return list({row["type"]: task_value(row) for row in rows}.values())


def item_status(rows):
    if any(row["status"] == "failed" and not (row["type"] in ("organize", "analyze") and row["error_code"] == "provider_refused") for row in rows):
        return "attention"
    return "processing" if any(row["status"] in ("waiting", "running") for row in rows) else "ready"


async def journal_statuses(identity, dreams):
    revisions = {row["id"]: row["revision"] for row in dreams}
    rows = await db.rwdb.execute_fetchall(f"SELECT dream_id,type,status,error_code,source_revision FROM tasks WHERE user_id=? AND type IN ('transcribe','organize','analyze') AND dream_id IN ({','.join('?' * len(revisions))}) ORDER BY updated_at,created_at,rowid", (identity, *revisions)) if revisions else []
    newest = {(row["dream_id"], row["type"]): row for row in rows if row["type"] == "transcribe" or row["source_revision"] == revisions[row["dream_id"]]}
    return {dream_id: item_status([row for (owner, _), row in newest.items() if owner == dream_id]) for dream_id in revisions}
