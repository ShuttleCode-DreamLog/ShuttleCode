import asyncio
import importlib.resources
import logging
import sqlite3
from contextlib import asynccontextmanager
from pathlib import Path

import aiosqlite
import config

rwdb = None
lock = None
# Pattern and search parts read this; the rest of the app works without vectors (wiki 4.8.3).
vectors = False


async def finish(statement):
    operation = asyncio.create_task(rwdb.execute(statement))
    cancelled = False
    while not operation.done():
        try:
            await asyncio.shield(operation)
        except asyncio.CancelledError:
            cancelled = True
    operation.result()
    if cancelled:
        raise asyncio.CancelledError


@asynccontextmanager
async def tx():
    async with lock:
        try:
            await rwdb.execute("BEGIN IMMEDIATE")
            yield rwdb
            await finish("COMMIT")
        except BaseException:
            try:
                await finish("ROLLBACK")
            except sqlite3.OperationalError as error:
                if str(error) != "cannot rollback - no transaction is active":
                    raise
            raise


def vector_path():
    return importlib.resources.files("sqlite_vector.binaries") / "vector"


async def load_vectors():
    global vectors
    try:
        await rwdb.enable_load_extension(True)
        await rwdb.load_extension(str(vector_path()))
        await rwdb.enable_load_extension(False)
        for table in ("dream_vectors", "occurrences"):
            await rwdb.execute_fetchall(f"SELECT vector_init('{table}', 'embedding', 'type=FLOAT32,dimension={config.EMBEDDING_DIMENSIONS},distance=COSINE')")
        vectors = True
    except (sqlite3.Error, AttributeError, OSError) as error:
        vectors = False
        logging.getLogger("dreamlog").error("vectors_unavailable error=%s", type(error).__name__)


async def open_database(path):
    global rwdb, lock
    lock = asyncio.Lock()
    rwdb = await aiosqlite.connect(path, autocommit=True)
    rwdb.row_factory = sqlite3.Row
    try:
        for setting in ("busy_timeout=5000", "temp_store=MEMORY", "journal_mode=WAL", "foreign_keys=ON", "secure_delete=ON"):
            await rwdb.execute(f"PRAGMA {setting}")
        version = (await rwdb.execute_fetchall("PRAGMA user_version"))[0][0]
        exists = await rwdb.execute_fetchall("SELECT 1 FROM sqlite_master WHERE name='users'")
        if (version or exists) and version not in (1, 2, 3, 4, config.SCHEMA_VERSION):
            raise RuntimeError(f"Schema version {version}; expected {config.SCHEMA_VERSION}")
        # Additive upgrades preserve journals, profiles and notes from earlier versions.
        schema = Path(__file__).with_name("schema.sql").read_text()
        await rwdb.executescript(f"BEGIN IMMEDIATE;\n{schema}\nPRAGMA user_version={config.SCHEMA_VERSION};\nCOMMIT;")
        await load_vectors()
        return rwdb
    except BaseException:
        await rwdb.close()
        rwdb = None
        raise
