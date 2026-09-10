-- שלוחת הדלקה/כיבוי שידורים (streamctl) — תפריט קולי בעברית
local API = "http://127.0.0.1:8765"
local SOUND_DIR = "/usr/share/freeswitch/sounds/he/streamctl"

local function play(name)
  session:streamFile(SOUND_DIR .. "/" .. name .. ".wav")
end

local function api_post(path)
  local cmd = string.format(
    "wget -q -O /dev/null --post-data='{}' --header='Content-Type: application/json' '%s%s' 2>/dev/null",
    API,
    path
  )
  local ok = os.execute(cmd)
  return ok == 0 or ok == true
end

session:setAutoHangup(false)
session:setVariable("playback_terminators", "none")

local digits = session:playAndGetDigits(
  1, 1, 3, 12000, "#",
  SOUND_DIR .. "/menu.wav",
  SOUND_DIR .. "/err.wav",
  "\\d",
  "streamctl_choice",
  8000
)

local choice = session:getVariable("streamctl_choice") or digits or ""
freeswitch.consoleLog("INFO", "streamctl choice: " .. choice .. "\n")

-- 1=הכל הדלק, 2=הכל כבה, 3/5=שלוחה 1, 4/6=שלוחה 2 (kanbet/kan11)
local path = nil
if choice == "1" then
  path = "/start/all"
elseif choice == "2" then
  path = "/stop/all"
elseif choice == "3" then
  path = "/start/1"
elseif choice == "4" then
  path = "/start/2"
elseif choice == "5" then
  path = "/stop/1"
elseif choice == "6" then
  path = "/stop/2"
else
  play("err")
  session:hangup()
  return
end

if api_post(path) then
  play("ok")
else
  play("err")
end

session:sleep(300)
session:hangup()
