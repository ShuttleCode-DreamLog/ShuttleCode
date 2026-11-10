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
        for table in ("dream_vectors", "memory_vectors", "occurrences"):
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
        if (version or exists) and version not in (1, 2, 3, 4, 5, 6, 7, 8, 9, config.SCHEMA_VERSION):
            raise RuntimeError(f"Schema version {version}; expected {config.SCHEMA_VERSION}")
        # Additive upgrades preserve journals, profiles and notes from earlier versions.
        schema = Path(__file__).with_name("schema.sql").read_text()
        # Version 10 adds the title_note task type. SQLite cannot widen a CHECK in place, so an earlier tasks table is set aside,
        # without the indexes that would follow it, and copied into the one schema.sql creates, in the same transaction.
        tasks_table = await rwdb.execute_fetchall("SELECT sql FROM sqlite_master WHERE type='table' AND name='tasks'")
        widen = bool(tasks_table) and "'title_note'" not in tasks_table[0][0]
        before = "ALTER TABLE tasks RENAME TO tasks_before_10;\nDROP INDEX IF EXISTS tasks_index_2;\nDROP INDEX IF EXISTS tasks_index_3;\nDROP INDEX IF EXISTS tasks_index_4;" if widen else ""
        after = "INSERT INTO tasks SELECT * FROM tasks_before_10;\nDROP TABLE tasks_before_10;" if widen else ""
        await rwdb.executescript(f"BEGIN IMMEDIATE;\n{before}\n{schema}\n{after}\nPRAGMA user_version={config.SCHEMA_VERSION};\nCOMMIT;")
        # Version 6 adds the note title; CREATE TABLE IF NOT EXISTS leaves a table from an earlier version without it.
        if "title" not in {row["name"] for row in await rwdb.execute_fetchall("PRAGMA table_info(memories)")}:
            await rwdb.execute("ALTER TABLE memories ADD COLUMN title TEXT")
        # Version 9 records whether a dream's title is the AI's, so organize renames it after an edit and never touches the user's.
        # Before it, a title equal to the latest generated one is the best evidence that the AI wrote it.
        if "title_generated" not in {row["name"] for row in await rwdb.execute_fetchall("PRAGMA table_info(dreams)")}:
            await rwdb.executescript("""BEGIN IMMEDIATE;
ALTER TABLE dreams ADD COLUMN title_generated INTEGER NOT NULL DEFAULT 0 CHECK(title_generated IN (0,1));
UPDATE dreams SET title_generated=1 WHERE title IN (SELECT json_extract(content,'$.title') FROM outputs WHERE outputs.dream_id=dreams.id AND type='organization');
COMMIT;""")
        # Version 10 records whether a note's title is the AI's, like a dream's; earlier note titles were all typed by the user.
        if "title_generated" not in {row["name"] for row in await rwdb.execute_fetchall("PRAGMA table_info(memories)")}:
            await rwdb.execute("ALTER TABLE memories ADD COLUMN title_generated INTEGER NOT NULL DEFAULT 0 CHECK(title_generated IN (0,1))")
        # Version 9 marks dismissed patterns; they keep their tags so neither the pattern nor its tags are offered to the AI again.
        if "dismissed_at" not in {row["name"] for row in await rwdb.execute_fetchall("PRAGMA table_info(pattern_groups)")}:
            await rwdb.execute("ALTER TABLE pattern_groups ADD COLUMN dismissed_at INTEGER")
        await load_vectors()
        return rwdb
    except BaseException:
        await rwdb.close()
        rwdb = None
        raise
