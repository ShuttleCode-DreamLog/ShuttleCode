import os
import time
from pathlib import Path

SCHEMA_VERSION = 3
MAX_NOTE_PHOTOS = 5
MAX_PHOTO_BYTES = 5000000
MAX_JSON_BYTES = 262144
CHECKIN_KEEP_DAYS = 14
LIMITS = dict(zip(("max_dream_chars", "max_title_chars", "max_memory_chars", "max_message_chars", "max_summary_chars", "max_tag_chars", "max_label_chars", "max_pattern_note_chars", "max_adjustment_chars", "max_scene_chars", "max_recording_seconds", "max_audio_bytes"), (20000, 120, 2000, 2000, 600, 60, 60, 300, 300, 4000, 600, 10000000), strict=True))
CAPS = {"text": 200, "image": 10, "video": 2}
PORT = int(os.environ.get("PORT", "443"))
TLS_CERT = Path(os.environ.get("TLS_CERT", "/home/ubuntu/dreamlog.crt"))
TLS_KEY = Path(os.environ.get("TLS_KEY", "/home/ubuntu/dreamlog.key"))


def data_directory():
    for key in ("DATA_DIR", "GEMINI_API_KEY"):
        if not os.environ.get(key):
            raise RuntimeError(f"Missing required configuration: {key}")
    return Path(os.environ["DATA_DIR"])


def now():
    return int(time.time() * 1000)
