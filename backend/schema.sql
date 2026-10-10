CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    timezone TEXT,
    reminder_weekday INTEGER CHECK(reminder_weekday BETWEEN 1 AND 7),
    use_history INTEGER NOT NULL DEFAULT 1 CHECK(use_history IN (0,1)),
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS profiles (
    user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    fields_json TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK(revision>=1),
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS dreams (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>=1),
    dream_date TEXT NOT NULL,
    title TEXT,
    mood TEXT CHECK(mood IN ('calm','happy','excited','confused','sad','anxious','afraid','angry')),
    source TEXT NOT NULL CHECK(source IN ('text','voice')),
    audio_status TEXT NOT NULL DEFAULT 'none' CHECK(audio_status IN ('none','expected','uploaded','transcribed','discarded')),
    audio_ms INTEGER,
    heard_text TEXT,
    transcript_model TEXT,
    transcript_instruction_version TEXT,
    allow_transcription INTEGER NOT NULL DEFAULT 1 CHECK(allow_transcription IN (0,1)),
    allow_analysis INTEGER NOT NULL DEFAULT 1 CHECK(allow_analysis IN (0,1)),
    allow_discussion INTEGER NOT NULL DEFAULT 1 CHECK(allow_discussion IN (0,1)),
    allow_history INTEGER NOT NULL DEFAULT 1 CHECK(allow_history IN (0,1)),
    allow_patterns INTEGER NOT NULL DEFAULT 1 CHECK(allow_patterns IN (0,1)),
    allow_visuals INTEGER NOT NULL DEFAULT 1 CHECK(allow_visuals IN (0,1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK(type IN ('transcribe','organize','analyze','index_dream','match_patterns','refresh_findings','generate_image','generate_video')),
    request_key TEXT NOT NULL UNIQUE,
    dream_id TEXT REFERENCES dreams(id) ON DELETE CASCADE,
    subject_id TEXT,
    source_revision INTEGER,
    status TEXT NOT NULL DEFAULT 'waiting' CHECK(status IN ('waiting','running','completed','failed','canceled','obsolete')),
    attempts INTEGER NOT NULL DEFAULT 0,
    run_after INTEGER NOT NULL,
    error_code TEXT,
    provider_op_id TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS outputs (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    dream_id TEXT NOT NULL REFERENCES dreams(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK(type IN ('organization','analysis')),
    dream_revision INTEGER NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    status TEXT NOT NULL DEFAULT 'current' CHECK(status IN ('current','outdated')),
    content TEXT NOT NULL,
    model TEXT NOT NULL,
    instruction_version TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sources (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    output_id TEXT REFERENCES outputs(id) ON DELETE CASCADE,
    message_id TEXT REFERENCES messages(id) ON DELETE CASCADE,
    label TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('dream','memory','output','notes')),
    source_id TEXT NOT NULL,
    source_revision INTEGER NOT NULL,
    source_date TEXT,
    cut_to INTEGER,
    indirect INTEGER NOT NULL DEFAULT 0 CHECK(indirect IN (0,1)),
    CHECK((output_id IS NOT NULL)+(message_id IS NOT NULL)=1)
);

CREATE TABLE IF NOT EXISTS usage (
    user_id TEXT NOT NULL,
    day TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('text','image','video')),
    count INTEGER NOT NULL,
    PRIMARY KEY(user_id,day,kind)
);

CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    dream_id TEXT REFERENCES dreams(id) ON DELETE CASCADE,
    checkin_id TEXT REFERENCES checkins(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    role TEXT NOT NULL CHECK(role IN ('user','assistant')),
    text TEXT NOT NULL,
    reply_to TEXT REFERENCES messages(id) ON DELETE CASCADE,
    state TEXT NOT NULL DEFAULT 'ok' CHECK(state IN ('ok','stale')),
    dream_revision INTEGER,
    offer TEXT CHECK(offer IN ('add_to_dream','remember_in_profile')),
    model TEXT,
    instruction_version TEXT,
    created_at INTEGER NOT NULL,
    CHECK((dream_id IS NOT NULL)+(checkin_id IS NOT NULL)=1)
);

CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY,
    output_id TEXT NOT NULL REFERENCES outputs(id) ON DELETE CASCADE,
    dream_id TEXT NOT NULL REFERENCES dreams(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category TEXT NOT NULL CHECK(category IN ('person','place','object','action','emotion','theme')),
    text TEXT NOT NULL,
    excerpt TEXT NOT NULL,
    feeling TEXT CHECK(feeling IN ('stated','inferred'))
);

CREATE TABLE IF NOT EXISTS org_corrections (
    output_id TEXT NOT NULL REFERENCES outputs(id) ON DELETE CASCADE,
    category TEXT NOT NULL CHECK(category IN ('summary','person','place','object','action','emotion','theme')),
    original_text TEXT NOT NULL,
    text TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY(output_id,category,original_text)
);

CREATE TABLE IF NOT EXISTS conversations (
    dream_id TEXT PRIMARY KEY REFERENCES dreams(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    goal TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS discussion_corrections (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    dream_id TEXT NOT NULL REFERENCES dreams(id) ON DELETE CASCADE,
    message_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
    section TEXT CHECK(section IN ('what_happened','emotional_movement','waking_life_connections','themes_and_readings','threat_and_response','related_dreams','reflection_questions')),
    output_id TEXT REFERENCES outputs(id) ON DELETE SET NULL,
    note TEXT NOT NULL CHECK(length(note)>0),
    created_at INTEGER NOT NULL,
    CHECK(message_id IS NULL OR section IS NULL)
);

CREATE TABLE IF NOT EXISTS memories (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    recorded_at INTEGER NOT NULL,
    event_date TEXT,
    event_precision TEXT NOT NULL CHECK(event_precision IN ('exact','approximate','unknown')),
    is_ongoing INTEGER NOT NULL DEFAULT 0 CHECK(is_ongoing IN (0,1)),
    allow_analysis INTEGER NOT NULL DEFAULT 1 CHECK(allow_analysis IN (0,1)),
    checkin_id TEXT REFERENCES checkins(id) ON DELETE SET NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>=1),
    updated_at INTEGER NOT NULL,
    CHECK((event_precision='unknown')=(event_date IS NULL))
);

CREATE TABLE IF NOT EXISTS memory_photos (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
    content_type TEXT NOT NULL CHECK(content_type IN ('image/jpeg','image/png')),
    content BLOB NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS memory_photos_owner ON memory_photos(user_id,memory_id,created_at,id);

CREATE TABLE IF NOT EXISTS checkins (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    week_start TEXT NOT NULL,
    opened_date TEXT NOT NULL,
    timezone TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','proposed','saved','skipped')),
    proposed_summary TEXT,
    summary_model TEXT,
    summary_instruction_version TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS dreams_index_0 ON dreams(user_id,dream_date,created_at);

CREATE INDEX IF NOT EXISTS dreams_index_1 ON dreams(user_id,mood);

CREATE INDEX IF NOT EXISTS tasks_index_2 ON tasks(status,run_after);

CREATE INDEX IF NOT EXISTS tasks_index_3 ON tasks(dream_id);

CREATE INDEX IF NOT EXISTS tasks_index_4 ON tasks(subject_id);

CREATE UNIQUE INDEX IF NOT EXISTS outputs_index_5 ON outputs(dream_id,type) WHERE status='current';

CREATE INDEX IF NOT EXISTS outputs_index_6 ON outputs(dream_id,type);

CREATE INDEX IF NOT EXISTS sources_index_7 ON sources(kind,source_id);

CREATE INDEX IF NOT EXISTS sources_index_8 ON sources(output_id);

CREATE INDEX IF NOT EXISTS sources_index_9 ON sources(message_id);

CREATE UNIQUE INDEX IF NOT EXISTS messages_index_10 ON messages(dream_id,seq);

CREATE UNIQUE INDEX IF NOT EXISTS messages_index_11 ON messages(checkin_id,seq);

CREATE UNIQUE INDEX IF NOT EXISTS messages_index_12 ON messages(reply_to);

CREATE UNIQUE INDEX IF NOT EXISTS tags_index_13 ON tags(output_id,category,text);

CREATE INDEX IF NOT EXISTS tags_index_14 ON tags(user_id,category,text);

CREATE INDEX IF NOT EXISTS tags_index_15 ON tags(dream_id);

CREATE INDEX IF NOT EXISTS discussion_corrections_index_16 ON discussion_corrections(dream_id,created_at);

CREATE INDEX IF NOT EXISTS memories_index_17 ON memories(user_id,recorded_at);

CREATE UNIQUE INDEX IF NOT EXISTS memories_index_18 ON memories(checkin_id) WHERE checkin_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS checkins_index_19 ON checkins(user_id,week_start);

DROP VIEW IF EXISTS effective_tags;
CREATE VIEW effective_tags AS
SELECT t.id AS tag_id,t.dream_id,t.user_id,t.output_id,t.category,t.excerpt,
       COALESCE(c.text,t.text) AS text,t.feeling,(c.output_id IS NOT NULL) AS corrected,
       t.text AS original_text,o.status AS output_status
FROM tags t JOIN outputs o ON o.id=t.output_id
LEFT JOIN org_corrections c ON c.output_id=t.output_id AND c.category=t.category AND c.original_text=t.text
WHERE COALESCE(c.text,t.text)<>'';
