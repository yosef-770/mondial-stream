#!/bin/sh
set -eu

ICECAST_HOST="${ICECAST_HOST:-icecast}"
ICECAST_PORT="${ICECAST_PORT:-8000}"
ICECAST_MOUNT="${ICECAST_MOUNT:-/mondial}"
ICECAST_SOURCE_PASSWORD="${ICECAST_SOURCE_PASSWORD:?ICECAST_SOURCE_PASSWORD is required}"
BITRATE="${STREAM_BITRATE:-64k}"
SAMPLE_RATE="${STREAM_SAMPLE_RATE:-16000}"
# מונו + פס טלפון + נרמול קל (בלי soxr כבד) — LQ נשאר מעומעם בנפרד למנויים
AUDIO_FILTER="${STREAM_AUDIO_FILTER:-aformat=channel_layouts=mono,highpass=f=90,lowpass=f=3400,dynaudnorm=f=500:g=11,aresample=${SAMPLE_RATE}}"
LQ_BITRATE="${STREAM_LQ_BITRATE:-16k}"
LQ_SAMPLE_RATE="${STREAM_LQ_SAMPLE_RATE:-8000}"
# לא-מנויים: מעומעם בכוונה (בלי dynaudnorm — הוא ביטל את ההפרש)
LQ_AUDIO_FILTER="${STREAM_LQ_AUDIO_FILTER:-aformat=channel_layouts=mono,highpass=f=650,lowpass=f=1250,acrusher=bits=5:samples=2:mix=0.75:mode=log,volume=-10dB,aresample=${LQ_SAMPLE_RATE}}"

# Backoff אחרי כשל קצר — מונע סערת reconnect
RETRY_SLEEP_MIN="${STREAM_RETRY_SLEEP_MIN:-5}"
RETRY_SLEEP_MAX="${STREAM_RETRY_SLEEP_MAX:-120}"
RETRY_RESET_AFTER_SEC="${STREAM_RETRY_RESET_AFTER_SEC:-60}"
RETRY_SLEEP="${RETRY_SLEEP_MIN}"

ICECAST_TARGET="icecast://source:${ICECAST_SOURCE_PASSWORD}@${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}"
ICECAST_TARGET_LQ="icecast://source:${ICECAST_SOURCE_PASSWORD}@${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}q"

# off/none/false/- = בלי proxy (לדריסת STREAM_HTTP_PROXY הגלובלי)
case "${STREAM_HTTP_PROXY:-}" in
  ""|off|OFF|none|NONE|false|FALSE|-) STREAM_HTTP_PROXY="" ;;
esac

# Build URL list: STREAM_URLS (comma/newline separated) or fallback to STREAM_URL
URLS=""
if [ -n "${STREAM_URLS:-}" ]; then
  URLS="$(printf '%s\n' "${STREAM_URLS}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')"
elif [ -n "${STREAM_URL:-}" ]; then
  URLS="${STREAM_URL}"
else
  echo "[stream-relay] ${ICECAST_MOUNT}: no STREAM_URL — idle"
  exec sleep infinity
fi

URL_COUNT="$(printf '%s\n' "${URLS}" | grep -c .)"
URL_INDEX=1

echo "[stream-relay] target: icecast://${ICECAST_HOST}:${ICECAST_PORT}${ICECAST_MOUNT}"
echo "[stream-relay] encode HQ: mp3 ${BITRATE} ${SAMPLE_RATE}Hz mono → ${ICECAST_MOUNT}"
echo "[stream-relay] encode LQ: mp3 ${LQ_BITRATE} ${LQ_SAMPLE_RATE}Hz mono → ${ICECAST_MOUNT}q"
echo "[stream-relay] retry backoff: ${RETRY_SLEEP_MIN}s…${RETRY_SLEEP_MAX}s (reset after ${RETRY_RESET_AFTER_SEC}s uptime)"
echo "[stream-relay] sources (${URL_COUNT}):"
printf '%s\n' "${URLS}" | while IFS= read -r u; do
  echo "[stream-relay]   - ${u}"
done

if [ -n "${STREAM_HTTP_PROXY:-}" ]; then
  echo "[stream-relay] proxy: ${STREAM_HTTP_PROXY}"
else
  echo "[stream-relay] proxy: (none)"
fi

is_twitch_channel() {
  case "$1" in
    *://www.twitch.tv/*|*://twitch.tv/*|*://m.twitch.tv/*) return 0 ;;
  esac
  return 1
}

is_x_broadcast() {
  case "$1" in
    *://x.com/i/broadcasts/*|*://www.x.com/i/broadcasts/*) return 0 ;;
    *://twitter.com/i/broadcasts/*|*://www.twitter.com/i/broadcasts/*) return 0 ;;
    *://x.com/i/spaces/*|*://www.x.com/i/spaces/*) return 0 ;;
    *://twitter.com/i/spaces/*|*://www.twitter.com/i/spaces/*) return 0 ;;
  esac
  return 1
}

is_twitch_signed_playlist() {
  case "$1" in
    *ttvnw.net*|*playlist.ttvnw.*) return 0 ;;
  esac
  return 1
}

pick_url() {
  printf '%s\n' "${URLS}" | sed -n "${URL_INDEX}p"
}

advance_url() {
  if [ "${URL_COUNT}" -le 1 ]; then
    return
  fi
  URL_INDEX=$((URL_INDEX + 1))
  if [ "${URL_INDEX}" -gt "${URL_COUNT}" ]; then
    URL_INDEX=1
  fi
  echo "[stream-relay] failover -> source #${URL_INDEX}/${URL_COUNT}"
}

# אחרי יציאה: אם רץ מספיק — מאפסים backoff; אחרת מכפילים עד המקסימום
after_exit_backoff() {
  started_at="$1"
  now="$(date +%s)"
  elapsed=$((now - started_at))
  if [ "${elapsed}" -ge "${RETRY_RESET_AFTER_SEC}" ]; then
    RETRY_SLEEP="${RETRY_SLEEP_MIN}"
    echo "[stream-relay] ran ${elapsed}s — reset backoff to ${RETRY_SLEEP}s"
  else
    echo "[stream-relay] exited after ${elapsed}s — retry in ${RETRY_SLEEP}s"
    sleep "${RETRY_SLEEP}"
    next=$((RETRY_SLEEP * 2))
    if [ "${next}" -gt "${RETRY_SLEEP_MAX}" ]; then
      next="${RETRY_SLEEP_MAX}"
    fi
    RETRY_SLEEP="${next}"
  fi
}

while true; do
  CURRENT_URL="$(pick_url)"
  USE_HLS_MAP=0
  case "${CURRENT_URL}" in
    *.m3u8*|*.livx*) USE_HLS_MAP=1 ;;
  esac

  echo "[stream-relay] starting ffmpeg at $(date -Iseconds)"
  echo "[stream-relay] source: ${CURRENT_URL}"
  START_TS="$(date +%s)"

  if is_twitch_signed_playlist "${CURRENT_URL}"; then
    echo "[stream-relay] Twitch signed playlist (ttvnw) expires within minutes."
    echo "[stream-relay] Use a stable URL: https://www.twitch.tv/CHANNEL"
    advance_url
    after_exit_backoff "${START_TS}"
    continue
  fi

  if is_twitch_channel "${CURRENT_URL}"; then
    # audio_only קודם; אם אין — וידאו נמוך בלבד (לא best)
    echo "[stream-relay] twitch via streamlink (audio_only / low video fallback)"
    set -- streamlink --stdout --loglevel warning \
      --retry-streams 8 \
      --retry-max 6 \
      --twitch-disable-ads
    if [ -n "${STREAM_HTTP_PROXY:-}" ]; then
      set -- "$@" --http-proxy "${STREAM_HTTP_PROXY}"
    fi
    if [ -n "${STREAM_USER_AGENT:-}" ]; then
      set -- "$@" --http-header "User-Agent=${STREAM_USER_AGENT}"
    fi
    set -- "$@" "${CURRENT_URL}" "audio_only,160p,360p,worst"
    if ! "$@" | ffmpeg -hide_banner -loglevel warning \
      -fflags +discardcorrupt+genpts+igndts \
      -err_detect ignore_err \
      -i pipe:0 \
      -map 0:a:0 -vn \
      -af "${AUDIO_FILTER}" \
      -acodec libmp3lame \
      -ab "${BITRATE}" \
      -ac 1 \
      -ar "${SAMPLE_RATE}" \
      -f mp3 \
      -content_type audio/mpeg \
      "${ICECAST_TARGET}" \
      -map 0:a:0 -vn \
      -af "${LQ_AUDIO_FILTER}" \
      -acodec libmp3lame \
      -ab "${LQ_BITRATE}" \
      -ac 1 \
      -ar "${LQ_SAMPLE_RATE}" \
      -f mp3 \
      -content_type audio/mpeg \
      "${ICECAST_TARGET_LQ}"
    then
      echo "[stream-relay] streamlink/ffmpeg exited"
      advance_url
    fi
    after_exit_backoff "${START_TS}"
    continue
  fi

  if is_x_broadcast "${CURRENT_URL}"; then
    echo "[stream-relay] X/Twitter broadcast via yt-dlp"
    # bestaudio אם יש; אחרת worst (לא best וידאו)
    set -- yt-dlp --no-warnings --no-playlist \
      -f "bestaudio/worst" \
      --hls-use-mpegts \
      -o -
    if [ -n "${STREAM_HTTP_PROXY:-}" ]; then
      set -- "$@" --proxy "${STREAM_HTTP_PROXY}"
    fi
    if [ -n "${STREAM_USER_AGENT:-}" ]; then
      set -- "$@" --user-agent "${STREAM_USER_AGENT}"
    fi
    if [ -n "${STREAM_COOKIES_FILE:-}" ] && [ -f "${STREAM_COOKIES_FILE}" ]; then
      set -- "$@" --cookies "${STREAM_COOKIES_FILE}"
    fi
    set -- "$@" "${CURRENT_URL}"
    if ! "$@" | ffmpeg -hide_banner -loglevel warning \
      -fflags +discardcorrupt+genpts+igndts \
      -err_detect ignore_err \
      -i pipe:0 \
      -map 0:a:0 -vn \
      -af "${AUDIO_FILTER}" \
      -acodec libmp3lame \
      -ab "${BITRATE}" \
      -ac 1 \
      -ar "${SAMPLE_RATE}" \
      -f mp3 \
      -content_type audio/mpeg \
      "${ICECAST_TARGET}" \
      -map 0:a:0 -vn \
      -af "${LQ_AUDIO_FILTER}" \
      -acodec libmp3lame \
      -ab "${LQ_BITRATE}" \
      -ac 1 \
      -ar "${LQ_SAMPLE_RATE}" \
      -f mp3 \
      -content_type audio/mpeg \
      "${ICECAST_TARGET_LQ}"
    then
      echo "[stream-relay] yt-dlp/ffmpeg exited"
      advance_url
    fi
    after_exit_backoff "${START_TS}"
    continue
  fi
  set -- ffmpeg -hide_banner -loglevel warning \
    -fflags +discardcorrupt+genpts+igndts \
    -err_detect ignore_err

  # HLS: בלי reconnect_at_eof — גורם ללולאת EOF על ה-playlist (במיוחד דרך proxy)
  if [ "${USE_HLS_MAP}" -eq 1 ]; then
    set -- "$@" \
      -reconnect 1 \
      -reconnect_streamed 1 \
      -reconnect_delay_max 5 \
      -probesize 32768 \
      -analyzeduration 500000 \
      -live_start_index -3
  else
    set -- "$@" -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_delay_max 5
  fi

  if [ -n "${STREAM_HTTP_PROXY:-}" ]; then
    set -- "$@" -http_proxy "${STREAM_HTTP_PROXY}"
  fi
  if [ -n "${STREAM_USER_AGENT:-}" ]; then
    set -- "$@" -user_agent "${STREAM_USER_AGENT}"
  fi
  if [ -n "${STREAM_HEADERS_FILE:-}" ] && [ -f "${STREAM_HEADERS_FILE}" ]; then
    # ffmpeg expects headers separated by CRLF, with a trailing CRLF
    HDRS="$(awk 'NF{printf "%s\r\n", $0}' "${STREAM_HEADERS_FILE}")"$'\r\n'
    set -- "$@" -headers "${HDRS}"
  elif [ -n "${STREAM_HEADERS:-}" ]; then
    set -- "$@" -headers "${STREAM_HEADERS}"
  fi

  set -- "$@" -i "${CURRENT_URL}"
  set -- "$@" \
    -map 0:a:0 -vn \
    -af "${AUDIO_FILTER}" \
    -acodec libmp3lame \
    -ab "${BITRATE}" \
    -ac 1 \
    -ar "${SAMPLE_RATE}" \
    -f mp3 \
    -content_type audio/mpeg \
    "${ICECAST_TARGET}" \
    -map 0:a:0 -vn \
    -af "${LQ_AUDIO_FILTER}" \
    -acodec libmp3lame \
    -ab "${LQ_BITRATE}" \
    -ac 1 \
    -ar "${LQ_SAMPLE_RATE}" \
    -f mp3 \
    -content_type audio/mpeg \
    "${ICECAST_TARGET_LQ}"

  if ! "$@"; then
    echo "[stream-relay] ffmpeg exited"
    advance_url
  fi
  after_exit_backoff "${START_TS}"
done
