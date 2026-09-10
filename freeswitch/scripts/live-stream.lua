-- שידור חי: בדיקת זמינות, השמעה, # ליציאה (ימות חוזר שלב אחורה)
-- אם הזרם נופל זמנית — מתחברים מחדש במקום לנתק את השיחה
local API = "http://127.0.0.1:8765"
local SOUND_DIR = "/usr/share/freeswitch/sounds/he/live"
local RECONNECT_WAIT_MS = 800
local OFF_RETRY_COUNT = 8
local OFF_RETRY_MS = 1000
local VOL_STEP = 3
local VOL_MIN = -12
local VOL_MAX = 12

local ALIASES = {
  kanbet = "1",
  kan11 = "2",
  mondial = "2",
}

local dest = (argv and argv[1]) or "1"
dest = ALIASES[dest] or dest
local quality = "hq"
local stream = dest
local dest_n = tonumber(dest)
if dest_n and dest_n >= 101 and dest_n <= 120 then
  quality = "low"
  stream = tostring(dest_n - 100)
elseif not (dest:match("^[1-9]$") or dest:match("^1[0-9]$") or dest:match("^20$")) then
  stream = "1"
end
local mount = stream
if quality == "low" then
  mount = stream .. "q"
end

local function apply_volume(s, vol)
  s:setVariable("live_vol", tostring(vol))
  s:setVariable("playback_volume", tostring(vol))
  local uuid = s:get_uuid()
  if uuid and uuid ~= "" then
    local lvl = math.floor(vol / VOL_STEP)
    if lvl > 4 then
      lvl = 4
    end
    if lvl < -4 then
      lvl = -4
    end
    local api = freeswitch.API()
    api:executeString(string.format("uuid_audio %s start read level %d", uuid, lvl))
  end
  freeswitch.consoleLog("INFO", "live-stream volume=" .. tostring(vol) .. " dB\n")
end

function live_stream_on_dtmf(s, typ, obj, arg)
  if typ ~= "dtmf" or not obj then
    return ""
  end
  local digit = obj["digit"] or obj.digit or ""
  freeswitch.consoleLog("INFO", "live-stream dtmf digit=" .. tostring(digit) .. "\n")
  if digit == "#" or digit == "*" then
    return "break"
  end
  if digit == "2" or digit == "0" then
    local vol = tonumber(s:getVariable("live_vol")) or 0
    if digit == "2" then
      vol = math.min(vol + VOL_STEP, VOL_MAX)
    else
      vol = math.max(vol - VOL_STEP, VOL_MIN)
    end
    apply_volume(s, vol)
    return ""
  end
  return ""
end

local function wget_body(url)
  local cmd = string.format("wget -q -O - '%s' 2>/dev/null", url)
  local h = io.popen(cmd)
  if not h then
    return ""
  end
  local body = h:read("*a") or ""
  h:close()
  return body
end

local function is_live()
  local body = wget_body(API .. "/live/" .. stream)
  return body:match("ok") ~= nil
end

local function play_off_message()
  if not session:ready() then
    return
  end
  local wav = SOUND_DIR .. "/off.wav"
  local mp3 = SOUND_DIR .. "/off.mp3"
  local f = io.open(wav, "r")
  if f then
    f:close()
    session:streamFile(wav)
    return
  end
  f = io.open(mp3, "r")
  if f then
    f:close()
    session:streamFile(mp3)
    return
  end
  freeswitch.consoleLog("WARNING", "live-stream: off audio missing in " .. SOUND_DIR .. "\n")
end

-- ממתין לחזרת Icecast אחרי נפילת relay קצרה
local function wait_until_live()
  for i = 1, OFF_RETRY_COUNT do
    if not session:ready() then
      return false
    end
    if is_live() then
      return true
    end
    freeswitch.consoleLog(
      "INFO",
      string.format("live-stream %s off — waiting %d/%d\n", stream, i, OFF_RETRY_COUNT)
    )
    session:sleep(OFF_RETRY_MS)
  end
  return is_live()
end

session:setAutoHangup(false)
-- שידור חד־כיווני: ימות לא שולחת RTP חזרה → בלי זה MEDIA_TIMEOUT אחרי ~2 דק'
session:setVariable("rtp_timeout_sec", "0")
session:setVariable("media_timeout", "0")

if not wait_until_live() then
  freeswitch.consoleLog("INFO", "live-stream " .. stream .. " off — playing message\n")
  play_off_message()
  session:sleep(200)
  session:hangup("NORMAL_CLEARING")
  return
end

-- shout לא מכבד playback_terminators — חייבים callback ל-DTMF
session:setInputCallback("live_stream_on_dtmf", "")
session:execute("bind_digit_action", "live,#,exec:hangup::NORMAL_CLEARING")
session:execute("bind_digit_action", "live,*,exec:hangup::NORMAL_CLEARING")
session:execute("digit_action_set_realm", "live")
if quality == "low" then
  apply_volume(session, -9)
else
  session:setVariable("live_vol", "0")
  session:setVariable("playback_volume", "0")
end

local shout = "shout://127.0.0.1:8000/" .. mount
freeswitch.consoleLog("INFO", "live-stream " .. stream .. " quality=" .. quality .. " — " .. shout .. "\n")

while session:ready() do
  if not is_live() then
    if not wait_until_live() then
      freeswitch.consoleLog("INFO", "live-stream " .. stream .. " stayed off — hangup\n")
      play_off_message()
      break
    end
  end

  freeswitch.consoleLog("INFO", "live-stream " .. stream .. " playing " .. shout .. "\n")
  session:streamFile(shout)

  if not session:ready() then
    break
  end

  -- הזרם נגמר (נפילת Icecast/relay) — לא מנתקים, מנסים שוב
  freeswitch.consoleLog("INFO", "live-stream " .. stream .. " ended — reconnecting\n")
  session:sleep(RECONNECT_WAIT_MS)
end

if session:ready() then
  session:hangup("NORMAL_CLEARING")
end
