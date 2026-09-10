#!/bin/sh
set -e

# FreeSWITCH עם RTP יוצר הרבה timerfd; ברירת מחדל 1024 קורסת תוך ימים
ulimit -n 65536 2>/dev/null || true

# קבצים שמתעדכנים מה-host (mount על vanilla)
SYNC_FILES="
dialplan/public/00_mondial.xml
scripts/streamctl.lua
scripts/live-stream.lua
autoload_configs/modules.conf.xml
autoload_configs/event_socket.conf.xml
autoload_configs/conference.conf.xml
autoload_configs/acl.conf.xml
sip_profiles/external.xml
vars.xml
"

if [ ! -f /etc/freeswitch/freeswitch.xml ]; then
  SIP_PASSWORD=$(tr -dc _A-Z-a-z-0-9 </dev/urandom | head -c12)
  mkdir -p /etc/freeswitch
  cp -varf /usr/share/freeswitch/conf/vanilla/* /etc/freeswitch/
  sed -i -e "s/default_password=.*\?/default_password=$SIP_PASSWORD\"/" /etc/freeswitch/vars.xml
  echo "New FreeSwitch password for SIP calls set to '$SIP_PASSWORD'"
fi

for f in $SYNC_FILES; do
  src="/usr/share/freeswitch/conf/vanilla/$f"
  dst="/etc/freeswitch/$f"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
  fi
done

# mod_lua טוען מ-/usr/share/freeswitch/scripts (לא מ-/etc/freeswitch/scripts)
if [ -f /usr/share/freeswitch/conf/vanilla/scripts/streamctl.lua ]; then
  mkdir -p /usr/share/freeswitch/scripts
  cp -f /usr/share/freeswitch/conf/vanilla/scripts/streamctl.lua /usr/share/freeswitch/scripts/streamctl.lua
fi

if [ -f /usr/share/freeswitch/conf/vanilla/scripts/live-stream.lua ]; then
  mkdir -p /usr/share/freeswitch/scripts
  cp -f /usr/share/freeswitch/conf/vanilla/scripts/live-stream.lua /usr/share/freeswitch/scripts/live-stream.lua
fi

if [ -d /usr/share/freeswitch/conf/vanilla/sounds/he/streamctl ]; then
  mkdir -p /usr/share/freeswitch/sounds/he/streamctl
  cp -rf /usr/share/freeswitch/conf/vanilla/sounds/he/streamctl/. /usr/share/freeswitch/sounds/he/streamctl/
fi

if [ -d /usr/share/freeswitch/conf/vanilla/sounds/he/live ]; then
  mkdir -p /usr/share/freeswitch/sounds/he/live
  cp -rf /usr/share/freeswitch/conf/vanilla/sounds/he/live/. /usr/share/freeswitch/sounds/he/live/
fi

if [ "$EPMD" = "true" ]; then
  /usr/bin/epmd -daemon
fi

trap '/usr/bin/freeswitch -stop' SIGTERM

/usr/bin/freeswitch -nc -nf -nonat &
pid="$!"
wait $pid
