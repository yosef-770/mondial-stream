#!/bin/bash
# הדלקה / כיבוי relays מהשרת (או דרך שלוחת streamctl בטלפון)
set -euo pipefail
cd "$(dirname "$0")/.."

API="http://127.0.0.1:8765"
cmd="${1:-status}"
target="${2:-}"

case "${cmd}" in
  status)
    curl -sf "${API}/status" | python3 -m json.tool
    ;;
  start|stop)
    if [ -z "${target}" ]; then
      echo "שימוש: $0 start|stop 1-20|kanbet|kan11|all" >&2
      exit 1
    fi
    curl -sf -X POST "${API}/${cmd}/${target}" | python3 -m json.tool
    ;;
  *)
    echo "שימוש: $0 status | $0 start|stop 1-20|kanbet|kan11|all" >&2
    exit 1
    ;;
esac
