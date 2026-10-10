import re
from uuid import UUID

import msgspec
from starlette.responses import Response
import db
import config


class RequestError(Exception):
    def __init__(self, status, code, message, current_revision=None):
        self.status, self.code, self.message = status, code, message
        self.current_revision = current_revision


def json_response(value, status=200):
    return Response(msgspec.json.encode(value), status_code=status, media_type="application/json")


def check_id(value):
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", value):
        raise RequestError(400, "invalid_request", "ID must be a lowercase UUID.")
    UUID(value)
    return value


async def resolve_user(request):
    header = request.headers.get("authorization", "")
    scheme, separator, identity = header.partition(" ")
    if not separator or scheme.lower() != "bearer":
        raise RequestError(401, "invalid_user", "A valid Bearer user ID is required.")
    try:
        identity = check_id(identity)
    except RequestError:
        raise RequestError(401, "invalid_user", "A valid Bearer user ID is required.") from None
    if not await db.rwdb.execute_fetchall("SELECT 1 FROM users WHERE id=?", (identity,)):
        async with db.tx() as connection:
            await connection.execute("INSERT INTO users(id,created_at) VALUES(?,?) ON CONFLICT(id) DO NOTHING", (identity, config.now()))
    return identity


async def read_body(request, body_type):
    length = request.headers.get("content-length")
    if length is not None:
        try:
            size = int(length)
        except ValueError:
            raise RequestError(400, "invalid_request", "Invalid Content-Length.") from None
        if size > config.MAX_JSON_BYTES:
            raise RequestError(413, "too_large", "Request body is too large.")
    data = bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data) > config.MAX_JSON_BYTES:
            raise RequestError(413, "too_large", "Request body is too large.")
    if request.headers.get("content-type", "").split(";")[0].lower() != "application/json":
        raise RequestError(400, "invalid_request", "Expected application/json.")
    try:
        return msgspec.json.decode(data, type=body_type)
    except msgspec.DecodeError:
        raise RequestError(400, "invalid_request", "Request fields have invalid types or JSON.") from None


def error_response(request, status, code, message, current_revision=None):
    return json_response({"error": code, "message": message, "request_id": request.scope.get("request_id", ""), "current_revision": current_revision}, status)


async def request_error(request, error):
    return error_response(request, error.status, error.code, error.message, error.current_revision)
