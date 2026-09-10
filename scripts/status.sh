#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d
echo ""
echo "=== סטטוס קונטיינרים ==="
docker compose ps
echo ""
echo "=== שידורים (Icecast) ==="
curl -s http://127.0.0.1:8000/status-json.xsl | python3 -c "
import json,sys
d=json.load(sys.stdin)
src=d.get('icestats',{}).get('source')
if not src:
    print('(אין מקור פעיל — הפעל דרך streamctl או ./scripts/stream-control.sh start all)')
    sys.exit(0)
if isinstance(src,dict): src=[src]
for s in src:
    url=s.get('listenurl','?')
    print(url, '| מאזינים:', s.get('listeners','?'))
" 2>/dev/null || echo "(Icecast עדיין עולה)"
echo ""
echo "=== relays ==="
./scripts/stream-control.sh status 2>/dev/null || echo "(stream-control עדיין עולה)"
echo ""
echo "שלוחות ימות → SIP (routing_extension):"
echo "  1…20     = STREAM_N_URL מ-.env (מנוי)"
echo "  101…120  = אותו שידור, איכות נמוכה (לא מנוי)"
echo "  kanbet   = כינוי ל-1"
echo "  kan11    = כינוי ל-2"
echo "  streamctl = הדלקה/כיבוי (DTMF)"
echo "  mondial  = כינוי ל-2 (legacy)"
