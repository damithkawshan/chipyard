#!/bin/bash
# Regenerates RESULTS.md whenever chain_status.txt changes, until the chain has finished. Read-only on the board side (never touches it).
S=$(cd "$(dirname "$0")/.." && pwd)
last=""
while true; do
  cur=$(stat -c %Y "$S/chain_status.txt" 2>/dev/null)
  if [ "$cur" != "$last" ]; then python3 "$S/tools/make_results.py" "$S" >/dev/null 2>&1; last=$cur; fi
  tail -n 3 "$S/chain_status.txt" | grep -q 'CHAIN FINISHED' && { python3 "$S/tools/make_results.py" "$S" >/dev/null 2>&1; break; }
  sleep 30
done
