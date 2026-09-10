#!/bin/sh
# המרת קובץ MP3 להודעת "שידור כבוי" (8kHz mono — מתאים לטלפון)
# שימוש:
#   ./scripts/set-off-air-audio.sh /path/to/p_16499589_591.mp3
set -eu

SRC="${1:?ציין נתיב לקובץ MP3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/freeswitch/sounds/he/live"
OUT_WAV="$OUT_DIR/off.wav"

mkdir -p "$OUT_DIR"

if [ ! -f "$SRC" ]; then
  echo "קובץ לא נמצא: $SRC" >&2
  exit 1
fi

cp -f "$SRC" "$OUT_DIR/off-source.mp3"
ffmpeg -y -hide_banner -loglevel error -i "$SRC" -ar 8000 -ac 1 -acodec pcm_s16le "$OUT_WAV"

echo "נוצר: $OUT_WAV"
ls -la "$OUT_WAV" "$OUT_DIR/off-source.mp3"
