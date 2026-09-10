#!/bin/bash
# הגדרת שלוחה 2 (kan11) לשידור כאן 11 TV — דורש גישה ישראלית ל-CDN (או proxy)
set -euo pipefail
cd "$(dirname "$0")/.."

URL='https://kancdn.medonecdn.net/livehls/oil/kancdn-live/live/kan11/live.livx/playlist.m3u8?bitrate=692000&audioId=1&videoId=16'
URLS="${URL},https://r.il.cdn-redge.media/livehls/oil/kancdn-live/live/kan11/live.livx/playlist.m3u8?bitrate=692000&audioId=1&videoId=16"

tmp="$(mktemp)"
grep -vE '^STREAM_2_URL=|^STREAM_2_URLS=' .env > "${tmp}" || true
{
  printf 'STREAM_2_URL=%s\n' "${URL}"
  printf 'STREAM_2_URLS=%s\n' "${URLS}"
} >> "${tmp}"
mv "${tmp}" .env

docker compose up -d --force-recreate stream-relay-2
echo ""
echo "שלוחה 2 → כאן 11 TV."
echo "בדיקה: curl -s http://127.0.0.1:8000/status-json.xsl"
echo "לוג:   docker logs mondial-stream-relay-2 --tail 20"
echo ""
echo "אם ffmpeg מקבל 403 — ה-CDN חוסם IP זר. צריך proxy/VPN ישראלי (STREAM_HTTP_PROXY ב-.env)."
