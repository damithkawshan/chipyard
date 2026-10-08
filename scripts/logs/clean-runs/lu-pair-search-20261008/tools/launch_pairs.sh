#!/bin/bash
# Single-core LU PAIR search: several (bA,bB) pairs of lu_ncb together on the one core, FRESH BOOT PER MEASURED WINDOW.   (2026-10-08)
#
#   usage:  STAGES="off:64,64 off:32,32 on:64,64" tools/launch_pairs.sh        (STAGES = the ordered list of "phase:bA,bB")
#
# Every stage: reprogram BIT1 -> boot -> stage -> ONE window. The same harness copy and the same checker as the b32+b128 pair
# test (../lu-pair-single-core-20261008/tools): OFF and ON go through the SAME steps, only --migrate=<phase> differs.
# Rules enforced here (refused at preflight): every OFF stage comes before any ON stage; an ON stage needs the matching OFF
# stage (already valid on disk, or earlier in the list).
# Validity gate after every stage: check_lupair_stage.py (judges only validity, never the size of the effect). A void run is kept
# under failed/, the stage is retried on a fresh boot after a SETTLE pause, and the chain STOPS when MAXATT attempts are void.
# Re-running resumes: a stage that already has a valid stage_result.json is skipped.
# Never passes -allow-*, never uses --reset-all. Does not edit the original harness. Does not commit anything.
set -u

CY=/home/damith/Research/repos/chipyard_performance_eval/chipyard
BIT1=$CY/fpga/bitstream_storage/FPGASingleRocketVCU118L18K256K8WL2ConfigSBCPLRU-256KB-8way-candidate013-2026-10-01-2026-10-01.bit
BIT1_SHA=5ace41250e7c5141                       # first 16 hex of sha256, recorded 2026-10-07
ORIG_HARNESS_SHA=b13d93e768b045598059            # first 20 hex of the ORIGINAL run_parsec_session.exp, recorded 2026-10-08
PAIR_HARNESS_SHA=1b8abefcbf4b                    # first 12 hex of the lupair copy, as recorded in the b32+b128 test's provenance
LOGS=$CY/scripts/logs
SEARCH=$LOGS/clean-runs/lu-pair-search-20261008
TOOLS=$LOGS/clean-runs/lu-pair-single-core-20261008/tools     # harness copy + checker of the b32+b128 pair test
HARNESS=$TOOLS/run_parsec_session.exp
CHECKER=$TOOLS/check_lupair_stage.py
ORIG_HARNESS=$CY/scripts/ssbc_scripts/run_parsec_session.exp
GEN=$SEARCH/tools/make_results.py
OUT=$SEARCH
STATUS=$OUT/chain_status.txt
VIV=$OUT/vivado                                 # cwd of every harness call: Vivado's journals land here
MAXATT=3
SETTLE=150                                      # seconds before a retry: lets the board's kernel write back to the SD card
PN=512
STAGES=${STAGES:-}

mkdir -p "$OUT/off" "$OUT/on" "$OUT/failed" "$OUT/results" "$VIV"
say() { echo "$@" | tee -a "$STATUS"; }
pre_fail() { say "CHAIN ABORT (preflight): $*"; exit 1; }
label_of() { echo "lupair-p1-n${PN}-b${1%,*}+b${1#*,}-plru"; }     # "64,128" -> lupair-p1-n512-b64+b128-plru

# ───────────── preflight: refuse to start on anything that is not exactly as planned ─────────────
[ -n "$STAGES" ] || pre_fail "STAGES is empty (e.g. STAGES=\"off:64,64 off:32,32\")"
seen_on=0
for st in $STAGES; do
  [[ "$st" =~ ^(off|on):[0-9]+,[0-9]+$ ]] || pre_fail "bad stage '$st' (want off:64,64 or on:64,64)"
  ph=${st%%:*}; pr=${st#*:}
  if [ "$ph" = on ]; then
    seen_on=1
    if [ ! -f "$OUT/off/$(label_of "$pr")/stage_result.json" ] && ! echo " $STAGES " | grep -q " off:$pr "; then
      pre_fail "ON stage for $pr has no OFF stage (none valid on disk, none earlier in STAGES)"
    fi
  elif [ $seen_on = 1 ]; then
    pre_fail "OFF stage '$st' after an ON stage: all OFF stages come before any ON stage"
  fi
done
[ -f "$BIT1" ]      || pre_fail "bitstream missing: $BIT1"
[ "$(sha256sum "$BIT1" | cut -c1-16)" = "$BIT1_SHA" ] || pre_fail "bitstream sha256 is not $BIT1_SHA"
[ -x "$HARNESS" ]   || pre_fail "harness not executable: $HARNESS"
[ "$(sha256sum "$HARNESS" | cut -c1-12)" = "$PAIR_HARNESS_SHA" ] || pre_fail "the lupair harness copy changed (sha256 is not $PAIR_HARNESS_SHA...)"
[ "$(sha256sum "$ORIG_HARNESS" | cut -c1-20)" = "$ORIG_HARNESS_SHA" ] || pre_fail "the ORIGINAL harness changed (sha256 is not $ORIG_HARNESS_SHA...)"
[ -f "$CHECKER" ]   || pre_fail "checker missing"
if ps -eo args= | grep -E '^[^ ]*expect( |$).*run_(pair|parsec)_session' | grep -v grep >/dev/null; then
  pre_fail "another measurement session owns the board"
fi
if ps -eo args= | grep -E 'picocom.*ttyUSB' | grep -v grep >/dev/null; then
  pre_fail "a picocom already holds the serial port"
fi
for st in $STAGES; do
  pr=${st#*:}; lab=$(label_of "$pr")
  "$HARNESS" -plan lupair -bit "$BIT1" -policy plru -pair-n $PN -pair-b "$pr" -list 2>&1 | grep -q "^  $lab " || pre_fail "label $lab is not in the harness plan"
done

{
  echo "CHAIN-START $(date '+%F %T')  stages=$(echo $STAGES | wc -w)  retries<=$((MAXATT-1))  STAGES=\"$STAGES\""
  echo "PROVENANCE bitstream  $BIT1  sha256=$(sha256sum "$BIT1" | cut -d' ' -f1)"
  echo "PROVENANCE harness    $HARNESS  sha256=$(sha256sum "$HARNESS" | cut -d' ' -f1)  (the lupair copy)"
  echo "PROVENANCE orig-harn  $ORIG_HARNESS  sha256=$(sha256sum "$ORIG_HARNESS" | cut -d' ' -f1)  (unchanged)"
  for f in "$CY"/scripts/ssbc_scripts/lib/*.exp; do echo "PROVENANCE lib        $f  sha256=$(sha256sum "$f" | cut -d' ' -f1)"; done
  echo "PROVENANCE checker    $CHECKER  sha256=$(sha256sum "$CHECKER" | cut -d' ' -f1)"
  echo "PROVENANCE launcher   $0  sha256=$(sha256sum "$0" | cut -d' ' -f1)  (MAXATT=$MAXATT SETTLE=${SETTLE}s)"
  echo "PROVENANCE sbc_read   $CY/generators/rocket-chip-inclusive-cache/sw/build/sbc_read  sha256=$(sha256sum "$CY/generators/rocket-chip-inclusive-cache/sw/build/sbc_read" | cut -d' ' -f1)"
  echo "PROVENANCE lu_ncb     $CY/software/parsec-benchmark/staged/lu_ncb  sha256=$(sha256sum "$CY/software/parsec-benchmark/staged/lu_ncb" | cut -d' ' -f1)"
  echo "PROVENANCE git        HEAD=$(git -C "$CY" rev-parse --short HEAD)  (the working tree has uncommitted edits; the shas above are what ran)"
} | tee -a "$STATUS"

# ───────────── one attempt = one fresh boot = one window ─────────────
run_attempt() {  # phase pair(a,b) attempt  -> 0 valid, 1 void
  local ph=$1 pr=$2 att=$3 lab before after csv log out js dest hrc chk ann bs
  lab=$(label_of "$pr"); bs=${pr/,/+b}
  before=$(ls -t "$LOGS"/lupair_runs_*.csv 2>/dev/null | head -1)
  say "STAGE-START $ph $lab attempt=$att $(date '+%F %T')"
  ( for i in $(seq 1 180); do
      n=$(ls -t "$LOGS"/lupair_runs_*.csv 2>/dev/null | head -1)
      if [ -n "$n" ] && [ "$n" != "$before" ]; then
        lg=${n/lupair_runs_/lupair_session_}; lg=${lg%.csv}.log
        say "STAGE-LOG $ph $lab attempt=$att log=$lg csv=$n"; break
      fi
      sleep 1
    done ) &
  ann=$!
  ( cd "$VIV" && "$HARNESS" -plan lupair -bit "$BIT1" -policy plru -pair-n $PN -pair-b "$pr" -bench "$lab" -phases "$ph" -repeat 1 )
  hrc=$?
  wait "$ann" 2>/dev/null
  after=$(ls -t "$LOGS"/lupair_runs_*.csv 2>/dev/null | head -1)
  if [ -z "$after" ] || [ "$after" = "$before" ]; then
    say "STAGE-VOID $ph $lab attempt=$att: the harness (exit $hrc) wrote no CSV"
    return 1
  fi
  csv=$after; log=${csv/lupair_runs_/lupair_session_}; log=${log%.csv}.log
  out=$OUT/.check_$$.txt; js=$OUT/.result_$$.json
  python3 "$CHECKER" --csv "$csv" --log "$log" --phase "$ph" --label "$lab" --bit "$BIT1" --bit-sha "$BIT1_SHA" --json "$js" > "$out" 2>&1
  chk=$?
  tee -a "$STATUS" < "$out"
  if [ $chk -eq 0 ]; then dest=$OUT/$ph/$lab; else dest=$OUT/failed/${ph}-${lab}-attempt${att}-$(date +%H%M%S); fi
  mkdir -p "$dest"
  mv -n "$csv" "$log" "$dest"/
  mv -n "$out" "$dest/stage_check.txt"
  [ -f "$js" ] && mv -n "$js" "$dest/stage_result.json"
  [ $hrc -ne 0 ] && say "NOTE harness exit code was $hrc (the stage verdict above is what counts)"
  if [ $chk -eq 0 ]; then say "STAGE-OK $ph $lab -> ${dest#$LOGS/}"; return 0; fi
  say "STAGE-VOID $ph $lab attempt=$att -> kept in ${dest#$LOGS/}"
  return 1
}

do_stage() {  # phase pair
  local ph=$1 pr=$2 att lab
  lab=$(label_of "$pr")
  if [ -f "$OUT/$ph/$lab/stage_result.json" ]; then say "STAGE-SKIP $ph $lab (valid result already on disk)"; return 0; fi
  for att in $(seq 1 $MAXATT); do
    run_attempt "$ph" "$pr" "$att" && return 0
    if [ "$att" -lt "$MAXATT" ]; then
      say "STAGE-RETRY $ph $lab: attempt $((att+1)) of $MAXATT on a fresh boot, after a ${SETTLE}s settle pause"
      sleep "$SETTLE"
    fi
  done
  say "CHAIN ABORT: $ph $lab was void on all $MAXATT attempts - stopping for a human"
  return 1
}

ok=1; n_ok=0; n_all=0
for st in $STAGES; do
  ph=${st%%:*}; pr=${st#*:}; n_all=$((n_all+1))
  say "STAGE $st begins $(date '+%F %T')"
  do_stage "$ph" "$pr" || { ok=0; break; }
  n_ok=$((n_ok+1))
done

say "CHAIN FINISHED $(date '+%F %T')  ok=$ok  valid_stages=$n_ok/$n_all"
if [ -f "$GEN" ]; then python3 "$GEN" "$OUT" 2>&1 | tee -a "$STATUS"; fi
echo "(window stays open - Ctrl-b d to detach, 'exit' to close)"
exec bash
