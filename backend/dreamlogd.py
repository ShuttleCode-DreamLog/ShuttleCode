from pathlib import Path
from granian.server import Server
from config import PORT, TLS_CERT, TLS_KEY

if __name__ == "__main__":
    Server("main:app", address="0.0.0.0", port=PORT, interface="asgi", loop="uvloop", log_access=False, ssl_cert=Path(TLS_CERT), ssl_key=Path(TLS_KEY), workers=1, workers_kill_timeout=3, respawn_failed_workers=True, respawn_interval=1.0).serve()
