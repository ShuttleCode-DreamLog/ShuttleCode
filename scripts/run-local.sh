#!/bin/sh
set -eu
cd "$(dirname "$0")/../backend"
command -v uv >/dev/null || { echo 'Install uv: https://docs.astral.sh/uv/getting-started/installation/' >&2; exit 1; }
uv sync --locked
mkdir -p .local
chmod 700 .local
if [ ! -f .local/server.key ] || [ ! -f .local/server.crt ]; then
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 100 \
        -keyout .local/server.key -out .local/server.crt -subj '/CN=127.0.0.1' \
        -addext 'subjectAltName=IP:127.0.0.1,DNS:localhost' \
        -addext 'extendedKeyUsage=serverAuth'
    chmod 600 .local/server.key
fi
export DATA_DIR="${DATA_DIR:-$PWD/.local/data}"
export TLS_CERT="${TLS_CERT:-$PWD/.local/server.crt}"
export TLS_KEY="${TLS_KEY:-$PWD/.local/server.key}"
export PORT="${PORT:-8443}"
# Foundation never calls an AI provider; a placeholder keeps the startup contract.
export GEMINI_API_KEY="${GEMINI_API_KEY:-foundation-local-no-ai}"
exec uv run --locked python dreamlogd.py
