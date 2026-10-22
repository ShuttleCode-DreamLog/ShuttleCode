import os
import time
from pathlib import Path

SCHEMA_VERSION = 6
MAX_NOTE_PHOTOS = 5
MAX_PHOTO_BYTES = 5000000
MAX_JSON_BYTES = 262144
CHECKIN_KEEP_DAYS = 14
LIMITS = dict(zip(("max_dream_chars", "max_title_chars", "max_memory_chars", "max_message_chars", "max_summary_chars", "max_tag_chars", "max_label_chars", "max_pattern_note_chars", "max_adjustment_chars", "max_scene_chars", "max_recording_seconds", "max_audio_bytes"), (20000, 120, 2000, 2000, 600, 60, 60, 300, 300, 4000, 600, 10000000), strict=True))
CAPS = {"text": 200, "image": 10, "video": 2}
CEILINGS = {"text": 2000, "image": 100, "video": 20}
MAX_ATTEMPTS = 3
RETRY_DELAYS = (15, 60)
RATE_LIMIT_DELAYS = (60, 300)
WORKER_MAX_WAIT_SECONDS = 30
START_WORKER = True
PROVIDER_TIMEOUT_SECONDS = 120
MAX_TAGS = 30
TAG_CATEGORIES = ("person", "place", "object", "action", "emotion", "theme")
MAX_CONTEXT_MEMORIES = 4
MEMORY_WINDOW_DAYS = 30
MIN_DREAM_MATCHES = 2
MAX_CONTEXT_DREAMS = 3
MAX_CONTEXT_DREAM_CHARS = 1500
SHORT_DREAM_CHARS = 300
ANALYSIS_WORDS_SHORT = 120
ANALYSIS_WORDS = 400
EMBEDDING_DIMENSIONS = 768
MAX_EMBED_CHARS = 6000
MAX_CANDIDATE_DISTANCE = 0.40
# A dream whose vector is farther than this from the search wording is left out of a ranked search (cosine distance). With
# gemini-embedding-001 on 21 October 2026, dreams that answered a search sat at 0.29–0.41 and unrelated ones at 0.43–0.55.
SEARCH_MAX_DISTANCE = 0.42
MAX_CANDIDATES = 10
MAX_MATCH_CANDIDATES = 30
GROUP_EXAMPLES = 3
RECURRING_MIN_DREAMS = 3
RELATED_MIN_DREAMS = 2
MAX_REFRESH_GROUPS = 10
GROUP_EVIDENCE_LIMIT = 8
PATTERN_PERIOD_DAYS = 30
MAX_EXAMPLES = 20
BACKFILL_SPACING_SECONDS = 20
CONTEXT_STOP_WORDS = frozenset("about above after again against almost along already always among another around because before behind being below between could doing during either every first going having herself himself itself little maybe might myself never other people really right should since something somewhere still their there these thing things think those though thought through under until wanted where which while without would yourself".split())
PORT = int(os.environ.get("PORT", "443"))
TLS_CERT = Path(os.environ.get("TLS_CERT", "/home/ubuntu/dreamlog.crt"))
TLS_KEY = Path(os.environ.get("TLS_KEY", "/home/ubuntu/dreamlog.key"))


def data_directory():
    for key in ("DATA_DIR", "VERTEX_PROJECT", "TEXT_MODEL", "EMBEDDING_MODEL"):
        if not os.environ.get(key):
            raise RuntimeError(f"Missing required configuration: {key}")
    return Path(os.environ["DATA_DIR"])


def now():
    return int(time.time() * 1000)
