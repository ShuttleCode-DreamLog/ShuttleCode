import asyncio
import logging
import os
import secrets
import sys
import time
import traceback
from contextlib import asynccontextmanager

import msgspec
from starlette.applications import Starlette
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.routing import Route
import httpx
import analysis
import config
import db
import patterns
import providers
import tasks
from dreams import delete_dream, get_dream, list_dreams, save_correction, save_dream, save_permissions, search_dreams
from memories import delete_memory, get_memory, list_memories, save_memory
from profiles import get_profile, save_profile
from photos import delete_photo, get_photo, save_photo
from config import data_directory
from records import delete_me, get_me, put_me
from web import RequestError, error_response, json_response, read_body, request_error

logging.basicConfig(level=logging.WARNING, stream=sys.stdout, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("dreamlog")
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


@asynccontextmanager
async def lifespan(app):
    directory = data_directory()
    for path in (directory, directory / "audio", directory / "media"):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    app.state.data_dir = directory
    app.state.rwdb = await db.open_database(directory / "dreamlog.db")
    tasks.wake = asyncio.Event()
    worker = None
    try:
        await tasks.restart()
        uploaded = {r[0] for r in await db.rwdb.execute_fetchall("SELECT id FROM dreams WHERE audio_status='uploaded'")}
        for path in (directory / "audio").iterdir():
            if path.is_file() and (path.suffix == ".part" or path.name.split('.')[0] not in uploaded):
                path.unlink()
        await patterns.backfill()
        providers.client = httpx.AsyncClient(timeout=httpx.Timeout(connect=5.0, read=None, write=None, pool=None), http2=True)
        worker = asyncio.create_task(tasks.worker()) if config.START_WORKER else None
        yield
    finally:
        if worker is not None:
            worker.cancel()
            try:
                await worker
            except asyncio.CancelledError:
                pass
        if providers.client is not None:
            await providers.client.aclose()
        await db.rwdb.close()


async def unexpected_error(request, error):
    return error_response(request, 500, "internal", "An unexpected server error occurred.")


async def framework_error(request, error):
    code = "not_found" if error.status_code == 404 else "invalid_request"
    return error_response(request, error.status_code, code, "Route not found." if error.status_code == 404 else "Method not allowed.")


class FaultBody(msgspec.Struct):
    text: str
    where: str


async def fault(request):
    body = await read_body(request, FaultBody)
    if body.where == "task":
        tasks.fault = body.text
        return json_response({})
    if body.where != "route":
        raise RequestError(400, "invalid_request", "A fault is raised in a route or in the next task.")
    raise RuntimeError(body.text)


routes = [Route("/v1/me", get_me, methods=["GET"]), Route("/v1/me", put_me, methods=["PUT"]), Route("/v1/me", delete_me, methods=["DELETE"])]
routes.extend([
    Route("/v1/me/profile", get_profile, methods=["GET"]),
    Route("/v1/me/profile", save_profile, methods=["PUT"]),
    Route("/v1/memories", list_memories, methods=["GET"]),
    Route("/v1/memories/{memory_id}/photos/{photo_id}", get_photo, methods=["GET"]),
    Route("/v1/memories/{memory_id}/photos/{photo_id}", save_photo, methods=["PUT"]),
    Route("/v1/memories/{memory_id}/photos/{photo_id}", delete_photo, methods=["DELETE"]),
    Route("/v1/memories/{memory_id}", get_memory, methods=["GET"]),
    Route("/v1/memories/{memory_id}", save_memory, methods=["PUT"]),
    Route("/v1/memories/{memory_id}", delete_memory, methods=["DELETE"]),
    Route("/v1/dreams", list_dreams, methods=["GET"]),
    Route("/v1/dreams/search", search_dreams, methods=["POST"]),
    Route("/v1/dreams/{dream_id}", get_dream, methods=["GET"]),
    Route("/v1/dreams/{dream_id}", save_dream, methods=["PUT"]),
    Route("/v1/dreams/{dream_id}", delete_dream, methods=["DELETE"]),
    Route("/v1/dreams/{dream_id}/permissions", save_permissions, methods=["PUT"]),
    Route("/v1/dreams/{dream_id}/corrections", save_correction, methods=["PUT"]),
    Route("/v1/dreams/{dream_id}/analysis", analysis.get_analysis, methods=["GET"]),
    Route("/v1/dreams/{dream_id}/analysis/refresh", analysis.refresh_analysis, methods=["POST"]),
    Route("/v1/patterns", patterns.get_patterns, methods=["GET"]),
    Route("/v1/patterns/groups/{group_id}/label", patterns.label_group, methods=["PUT"]),
    Route("/v1/patterns/groups/{group_id}/dismiss", patterns.dismiss_group, methods=["POST"]),
    Route("/v1/patterns/groups/{group_id}/split", patterns.split_group, methods=["POST"]),
    Route("/v1/tasks/{task_id}/retry", tasks.retry_task, methods=["POST"]),
])
if os.environ.get("DREAMLOG_FAULTS") == "1":
    routes.append(Route("/v1/faults", fault, methods=["POST"]))
application = Starlette(lifespan=lifespan, routes=routes, exception_handlers={RequestError: request_error, HTTPException: framework_error, Exception: unexpected_error})


async def app(scope, receive, send):
    if scope["type"] != "http":
        return await application(scope, receive, send)
    request_id = secrets.token_hex(6)
    scope["request_id"] = request_id
    status = 500
    sent = False
    started = time.monotonic()
    async def respond(message):
        nonlocal status, sent
        if message["type"] == "http.response.start":
            sent = True
            status = message["status"]
            message.setdefault("headers", []).append((b"x-request-id", request_id.encode()))
        await send(message)
    try:
        await application(scope, receive, respond)
    except Exception as error:
        location = traceback.extract_tb(error.__traceback__)[-1]
        logger.error("request_id=%s error=%s file=%s line=%s", request_id, type(error).__name__, location.filename, location.lineno)
        # Starlette raises after its sanitized response; suppress content-bearing reports.
        if not sent:
            response = error_response(Request(scope), 500, "internal", "An unexpected server error occurred.")
            await response(scope, receive, respond)
    finally:
        logger.info("request_id=%s path=%s status=%s duration_ms=%d", request_id, scope.get("path"), status, (time.monotonic() - started) * 1000)
