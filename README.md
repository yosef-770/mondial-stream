# mondial-stream

מערכת שידור חי לטלפון דרך **ימות המשיח + FreeSWITCH**.

ימות מעביר **שיחת SIP בלבד** — השמע מושמע ע"י FreeSWITCH (לא דרך `music_on_hold` / זרם בימotes).

```
מקור אינטרנט (MP3/HLS) → ffmpeg → Icecast → FreeSWITCH → מתקשר
```

עד **9 שלוחות** — כל אחת עם `STREAM_N_URL` ב-`.env`.

---

## דרישות מקדימות

- Linux עם **Docker** ו-**Docker Compose** (v2)
- **פורט 5060 פנוי** (SIP) — אם תפוס, ראה «שינוי פורט» למטה
- גישה לפתיחת פורטים ב-firewall:
  - `5060/udp` + `5060/tcp` — SIP
  - `16384:32768/udp` — RTP (שמע)

---

## התקנה בשרת חדש — צעד אחר צעד

### 1. משיכת הפרויקט

```bash
cd /srv
git clone <URL-REPO> mondial-stream
cd mondial-stream
```

### 2. קובץ סביבה

```bash
cp .env.example .env
```

ערוך `.env`:

| משתנה | תיאור |
|--------|--------|
| `ICECAST_SOURCE_PASSWORD` | סיסמת מקור ל-Icecast (שנה בפרודקשן) |
| `ICECAST_RELAY_PASSWORD` | סיסמת relay |
| `ICECAST_ADMIN_PASSWORD` | סיסמת admin |
| `STREAM_1_URL` … `STREAM_20_URL` | כתובת MP3/HLS לכל שלוחה (ריק = לא פעיל) |
| `STREAM_N_URLS` | רשימת failover מופרדת בפסיקים (אופציונלי) |

**ברירת מחדל:** שלוחה 1 = רדיו כאן ב', שלוחה 2 = כאן 11.

### 3. Icecast — קובץ קונפיג מקומי

```bash
cp icecast/icecast.xml.example icecast/icecast.xml
```

ערוך `icecast/icecast.xml` — הסיסמאות חייבות להתאים ל-`.env` (`ICECAST_SOURCE_PASSWORD` וכו').

### 4. כתובת IP ציבורית של השרת

ערוך `freeswitch/vars.xml` — החלף `91.98.89.80` ב-IP הציבורי של השרת החדש:

```xml
<X-PRE-PROCESS cmd="set" data="external_rtp_ip=YOUR.PUBLIC.IP"/>
<X-PRE-PROCESS cmd="set" data="external_sip_ip=YOUR.PUBLIC.IP"/>
```

פורט SIP (ברירת מחדל):

```xml
<X-PRE-PROCESS cmd="set" data="external_sip_port=5060"/>
```

### 5. Firewall

```bash
ufw allow 5060/udp comment 'SIP mondial'
ufw allow 5060/tcp comment 'SIP mondial'
ufw allow 16384:32768/udp comment 'RTP mondial'
```

### 6. הרצה

```bash
docker compose up -d
```

המתן ~15 שניות, ואז:

```bash
./scripts/status.sh
```

### 7. בדיקת שמע (מהשרת)

```bash
curl -s http://127.0.0.1:8000/status-json.xsl | head -c 200
# או:
ffplay http://127.0.0.1:8000/1
```

### 8. חיבור ימות המשיח

העתק מ-`YEMOT-CONFIG.txt` לשלוחה בימotes (`ext.ini`):

```ini
type=routing_ip
routing_ip=YOUR.PUBLIC.IP
routing_ip_port=5060
routing_extension=1
routing_ip_dial_time=60
```

`routing_extension` = מספר השלוחה (`1`–`20`) שמתאים ל-`STREAM_N_URL`.
ללא-מנוי: אותו בלוק עם `routing_extension=100+N` (למשל `103` לשלוחה 3) — אותו שידור, איכות נמוכה.

כינויים לתאימות לאחור: `kanbet`→1, `kan11`/`mondial`→2, `streamctl`→תפריט הדלקה/כיבוי.

**אל תשתמש** ב-`music_on_hold`, רישום זרם, או URL שמע בפאנל ימotes.

---

## פקודות שימושיות

```bash
# סטטוס + הפעלה
./scripts/status.sh

# הפעלה / עצירה / הפעלה מחדש
docker compose up -d
docker compose down
docker compose restart

# הדלקה/כיבוי relays
./scripts/stream-control.sh status
./scripts/stream-control.sh start all
./scripts/stream-control.sh stop 2

# לוגים
docker logs mondial-freeswitch --tail 50
docker logs mondial-stream-relay-1 --tail 30
docker logs mondial-icecast --tail 20

# FreeSWITCH CLI
docker exec mondial-freeswitch /usr/bin/fs_cli -P 8022 -x "sofia status profile external"
docker exec mondial-freeswitch /usr/bin/fs_cli -P 8022 -x "show channels count"

# ניתוק כל השיחות
docker exec mondial-freeswitch /usr/bin/fs_cli -P 8022 -x "hupall"
```

---

## החלפת מקור שידור

ערוך ישירות ב-`.env`:

```env
STREAM_3_URL=https://example.com/live.mp3
```

ואז:

```bash
docker compose up -d --force-recreate stream-relay-3
```

**Twitch:** רק כתובת הערוץ (לא קישור `.m3u8` מ-`ttvnw.net` — הוא פג מהר):

```env
STREAM_5_URL=https://www.twitch.tv/CHANNEL
STREAM_5_HTTP_PROXY=off
```

**X (שידור חי / Spaces):** דף `x.com/i/broadcasts/...` או `x.com/i/spaces/...` — yt-dlp מרענן את ה-HLS. אם X דורש התחברות, צריך קובץ עוגיות (`STREAM_N_COOKIES_FILE`).

```env
STREAM_11_URL=https://x.com/i/broadcasts/BROADCAST_ID
STREAM_11_HTTP_PROXY=off
```

```bash
docker compose up -d --build --force-recreate stream-relay-5
```

קיצורים לקיימים:

```bash
./scripts/use-kan-bet-radio.sh   # STREAM_1_URL = רדיו כאן ב'
./scripts/use-kan11-tv.sh        # STREAM_2_URL = כאן 11 TV
```

---

## מבנה הפרויקט

```
mondial-stream/
├── docker-compose.yml          # icecast, stream-relay-1..20, stream-control, freeswitch
├── docker/stream-relay.Dockerfile  # ffmpeg + streamlink (Twitch)
├── .env / .env.example         # STREAM_N_URL + סיסמאות
├── YEMOT-CONFIG.txt            # הגדרות ימות להעתקה
├── README.md                   # קובץ זה
│
├── icecast/icecast.xml         # שרת סטרימינג מקומי (פורט 8000, mounts /1…/20)
├── scripts/
│   ├── stream-relay.sh         # ffmpeg: STREAM_URL → Icecast
│   ├── stream-control-server.py
│   ├── stream-control.sh
│   ├── status.sh
│   ├── freeswitch-entrypoint.sh
│   ├── use-kan-bet-radio.sh
│   └── use-kan11-tv.sh
│
└── freeswitch/
    ├── vars.xml
    ├── dialplan/public/00_mondial.xml
    ├── scripts/live-stream.lua
    ├── scripts/streamctl.lua
    ├── sip_profiles/external.xml
    └── autoload_configs/
```

---

## שירותים

| שירות | קונטיינר | תפקיד |
|--------|-----------|--------|
| **icecast** | `mondial-icecast` | שרת MP3 מקומי — `127.0.0.1:8000/N` |
| **stream-relay-N** | `mondial-stream-relay-N` | ffmpeg דוחף `STREAM_N_URL` ל-Icecast |
| **stream-control** | `mondial-stream-control` | API הדלקה/כיבוי + בדיקת live |
| **freeswitch** | `mondial-freeswitch` | SIP :5060, מנגן שמע לשיחה (`mod_shout`) |

FreeSWITCH רץ ב-`network_mode: host` (SIP/RTP ישירות על השרת).

---

## איך שיחה עובדת

1. מתקשר → ימות → SIP ל-`YOUR.IP:5060` עם `routing_extension=N`
2. FreeSWITCH (ACL: רק IP ימות `185.243.5.118`) מקבל
3. Dialplan: `answer` → `live-stream.lua N`
4. `mod_shout` קורא מ-`shout://127.0.0.1:8000/N` → שמע למתקשר
5. בשיחה: `2` מגביר, `0` מנמיך, `#`/`*` יציאה (ימות חוזר)

---

## שינוי פורט SIP

אם 5060 תפוס (למשל FreeSWITCH אחר):

1. שנה `external_sip_port` ב-`freeswitch/vars.xml`
2. עדכן `routing_ip_port` בימotes
3. עדכן firewall
4. `docker compose restart freeswitch`

---

## פתרון בעיות

| תסמין | בדיקה / פתרון |
|--------|----------------|
| אין שמע | `curl http://127.0.0.1:8000/1` — האם ffmpeg רץ? `docker logs mondial-stream-relay-1` |
| שיחה נכשלת ~20 שנ' | ימות לא מגיע ל-5060 — בדוק `routing_ip_port` ו-firewall |
| אין INVITE בלוג | `docker exec mondial-freeswitch grep INVITE /var/log/freeswitch/freeswitch.log \| tail` |
| `CALLS-IN: 0` | IP שגוי ב-`vars.xml` או ACL חוסם — וודא IP ימotes ב-`acl.conf.xml` |
| ערוצים תקועים | `docker exec mondial-freeswitch /usr/bin/fs_cli -P 8022 -x "hupall"` |

---

## הערות ל-Cursor / AI

כשמבקשים «להריץ את הפרויקט» בשרת חדש:

1. וודא Docker מותקן
2. `cp .env.example .env` — ערוך סיסמאות ו-`STREAM_1_URL`…`STREAM_20_URL`
3. סנכרן סיסמאות ל-`icecast/icecast.xml`
4. עדכן `external_rtp_ip` + `external_sip_ip` ב-`freeswitch/vars.xml` ל-IP הציבורי
5. פתח firewall: 5060 + 16384-32768/udp
6. `docker compose up -d`
7. `./scripts/status.sh` — וודא קונטיינרים Up + Icecast עם שידור
8. הגדר ימotes לפי `YEMOT-CONFIG.txt` (`routing_extension=1` וכו')

**לא** להשתמש ב-`music_on_hold` בימotes. **לא** לגשר דרך FreeSWITCH אחר — ישיר ל-5060.
