import asyncio
import sqlite3
from contextlib import asynccontextmanager
from pathlib import Path

import aiosqlite
import config

rwdb = None
lock = None


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
        if (version or exists) and version not in (1, 2, config.SCHEMA_VERSION):
            raise RuntimeError(f"Schema version {version}; expected {config.SCHEMA_VERSION}")
        # Additive upgrades preserve journals, profiles and notes from earlier versions.
        schema = Path(__file__).with_name("schema.sql").read_text()
        await rwdb.executescript(f"BEGIN IMMEDIATE;\n{schema}\nPRAGMA user_version={config.SCHEMA_VERSION};\nCOMMIT;")
        return rwdb
    except BaseException:
        await rwdb.close()
        rwdb = None
        raise
