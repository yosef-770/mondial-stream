#!/bin/bash
# הרצה על Mac בישראל — חלון 2 (אחרי SSH tunnel בחלון 1)
# ssh -N -L 8000:127.0.0.1:8000 root@91.98.89.80
set -euo pipefail

ffmpeg -hide_banner -loglevel warning \
  -headers "Referer: https://www.kan.org.il/live/\r\nOrigin: https://www.kan.org.il\r\n" \
  -user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -fflags +discardcorrupt+genpts \
  -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
  -i "https://kancdn.medonecdn.net/livehls/oil/kancdn-live/live/kan11/live.livx/playlist.m3u8?bitrate=692000&audioId=1&videoId=16" \
  -map 0:a:0 \
  -acodec libmp3lame -ab 64k -ac 1 -ar 44100 -f mp3 \
  -content_type audio/mpeg \
  "icecast://source:mondial-src-7kP2@127.0.0.1:8000/mondial"
