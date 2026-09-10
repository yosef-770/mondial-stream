#!/bin/bash
# הגדרת שלוחה 1 (kanbet) לרדיו כאן ב'
set -euo pipefail
cd "$(dirname "$0")/.."

URL='https://playerservices.streamtheworld.com/api/livestream-redirect/KAN_BET.mp3'

tmp="$(mktemp)"
grep -vE '^STREAM_1_URL=|^STREAM_1_URLS=' .env > "${tmp}" || true
printf 'STREAM_1_URL=%s\n' "${URL}" >> "${tmp}"
mv "${tmp}" .env

docker compose up -d --force-recreate stream-relay-1
echo "שלוחה 1 → רדיו כאן ב'. בדוק: curl -s http://127.0.0.1:8000/status-json.xsl"
