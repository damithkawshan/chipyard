#!/bin/bash
# Single-core LU sweep, FRESH BOOT PER MEASURED WINDOW, one run per arm.   (2026-10-08, user request)
#
#   9 points  x  2 arms  =  18 stages.  Every stage: reprogram BIT1 -> boot -> stage -> ONE window.
#   All 9 migrate=off stages first, then all 9 migrate=on stages (phase order is absolute).
#   OFF and ON go through the SAME harness steps; the only difference is --migrate=<phase>.
#
# Validity gate after every stage (tools/check_lu_stage.py): a VOID run is kept under failed/, the stage
# is retried on a fresh boot after a SETTLE pause, and the chain STOPS when MAXATT attempts are void. The
# gate judges only whether the run is valid, never how big the effect is, so a retry cannot pick a nicer
# number. v2 (2026-10-08 02:50): MAXATT 2 -> 3 and the SETTLE pause. v1 (kept as launch_lu_sweep.sh.v1) ran
# stages 1-4; after stage 4 attempt 1 failed during staging, attempt 2 reprogrammed the FPGA at once and the
# board then printed nothing for 17 minutes (see PLAN.md addendum). A manual reprogram brought it back.
#
# Re-running this script resumes: a stage that already has a valid stage_result.json is skipped.
# Never passes -allow-*, never uses --reset-all. Does not edit the harness. Does not commit anything.
set -u

CY=/home/damith/Research/repos/chipyard_performance_eval/chipyard
BIT1=$CY/fpga/bitstream_storage/FPGASingleRocketVCU118L18K256K8WL2ConfigSBCPLRU-256KB-8way-candidate013-2026-10-01-2026-10-01.bit
BIT1_SHA=5ace41250e7c5141                       # first 16 hex of sha256, recorded 2026-10-07
LOGS=$CY/scripts/logs
SWEEP=$LOGS/clean-runs/lu-sweep-single-core-20261008
TOOLS=$SWEEP/tools
HARNESS=$CY/scripts/ssbc_scripts/run_parsec_session.exp
STATUS=$SWEEP/chain_status.txt
VIV=$SWEEP/vivado                               # cwd of every harness call: Vivado's journals land here
MAXATT=3
SETTLE=150                                      # seconds to wait before a retry: lets the board's kernel write
                                                # back anything dirty to the SD card before the FPGA is reset

LABELS=(                                         # the harness's own plan order: centre, n axis, b axis
  lu-p1-n512-b128-plru
  lu-p1-n256-b128-plru
  lu-p1-n384-b128-plru
  lu-p1-n768-b128-plru
  lu-p1-n1024-b128-plru
  lu-p1-n512-b16-plru
  lu-p1-n512-b32-plru
  lu-p1-n512-b64-plru
  lu-p1-n512-b256-plru
)
HARNESS_ARGS=(-plan lu -bit "$BIT1" -policy plru -lu-centre 1,512,128 -lu-p 1 -lu-policy plru
              -lu-n 256,384,512,768,1024 -lu-b 16,32,64,128,256)

mkdir -p "$SWEEP/off" "$SWEEP/on" "$SWEEP/failed" "$VIV"
say() { echo "$@" | tee -a "$STATUS"; }

# ───────────── preflight: refuse to start on anything that is not exactly as planned ─────────────
pre_fail() { say "CHAIN ABORT (preflight): $*"; exit 1; }
[ -f "$BIT1" ]      || pre_fail "bitstream missing: $BIT1"
[ "$(sha256sum "$BIT1" | cut -c1-16)" = "$BIT1_SHA" ] || pre_fail "bitstream sha256 is not $BIT1_SHA"
[ -x "$HARNESS" ]   || pre_fail "harness not executable: $HARNESS"
[ -f "$TOOLS/check_lu_stage.py" ] || pre_fail "checker missing"
if ps -eo args= | grep -E '^[^ ]*expect( |$).*run_(pair|parsec)_session' | grep -v grep >/dev/null; then
  pre_fail "another measurement session owns the board"
fi
PLAN_LIST=$("$HARNESS" "${HARNESS_ARGS[@]}" -list 2>&1)
for lab in "${LABELS[@]}"; do
  echo "$PLAN_LIST" | grep -q "^  $lab " || pre_fail "label $lab is not in the harness plan"
done
[ "$(echo "$PLAN_LIST" | grep -c '^  lu-p')" = "${#LABELS[@]}" ] || pre_fail "the harness plan has a different number of points than this script"

{
  echo "CHAIN-START $(date '+%F %T')  stages=$(( ${#LABELS[@]} * 2 ))  retries<=$((MAXATT-1))"
  echo "PROVENANCE bitstream  $BIT1  sha256=$(sha256sum "$BIT1" | cut -d' ' -f1)"
  echo "PROVENANCE harness    $HARNESS  sha256=$(sha256sum "$HARNESS" | cut -d' ' -f1)"
  for f in "$CY"/scripts/ssbc_scripts/lib/*.exp; do echo "PROVENANCE lib        $f  sha256=$(sha256sum "$f" | cut -d' ' -f1)"; done
  echo "PROVENANCE checker    $TOOLS/check_lu_stage.py  sha256=$(sha256sum "$TOOLS/check_lu_stage.py" | cut -d' ' -f1)"
  echo "PROVENANCE launcher   $0  sha256=$(sha256sum "$0" | cut -d' ' -f1)  (v2; MAXATT=$MAXATT SETTLE=${SETTLE}s)"
  echo "PROVENANCE sbc_read   $CY/generators/rocket-chip-inclusive-cache/sw/build/sbc_read  sha256=$(sha256sum "$CY/generators/rocket-chip-inclusive-cache/sw/build/sbc_read" | cut -d' ' -f1)"
  echo "PROVENANCE lu_ncb     $CY/software/parsec-benchmark/staged/lu_ncb  sha256=$(sha256sum "$CY/software/parsec-benchmark/staged/lu_ncb" | cut -d' ' -f1)"
  echo "PROVENANCE git        HEAD=$(git -C "$CY" rev-parse --short HEAD)  (the working tree has uncommitted edits; the shas above are what ran)"
} | tee -a "$STATUS"

# ───────────── one attempt = one fresh boot = one window ─────────────
run_attempt() {  # phase label attempt  -> 0 valid, 1 void
  local ph=$1 lab=$2 att=$3 before after csv log out js dest hrc chk ann
  before=$(ls -t "$LOGS"/lu_runs_*.csv 2>/dev/null | head -1)
  say "STAGE-START $ph $lab attempt=$att $(date '+%F %T')"
  # say where the transcript is the moment the harness creates it
  ( for i in $(seq 1 180); do
      n=$(ls -t "$LOGS"/lu_runs_*.csv 2>/dev/null | head -1)
      if [ -n "$n" ] && [ "$n" != "$before" ]; then
        lg=${n/lu_runs_/lu_session_}; lg=${lg%.csv}.log
        say "STAGE-LOG $ph $lab attempt=$att log=$lg csv=$n"; break
      fi
      sleep 1
    done ) &
  ann=$!
  ( cd "$VIV" && "$HARNESS" "${HARNESS_ARGS[@]}" -bench "$lab" -phases "$ph" -repeat 1 )
  hrc=$?
  wait "$ann" 2>/dev/null
  after=$(ls -t "$LOGS"/lu_runs_*.csv 2>/dev/null | head -1)
  if [ -z "$after" ] || [ "$after" = "$before" ]; then
    say "STAGE-VOID $ph $lab attempt=$att: the harness (exit $hrc) wrote no CSV"
    return 1
  fi
  csv=$after; log=${csv/lu_runs_/lu_session_}; log=${log%.csv}.log
  out=$SWEEP/.check_$$.txt; js=$SWEEP/.result_$$.json
  python3 "$TOOLS/check_lu_stage.py" --csv "$csv" --log "$log" --phase "$ph" --label "$lab" \
          --bit "$BIT1" --bit-sha "$BIT1_SHA" --json "$js" > "$out" 2>&1
  chk=$?
  tee -a "$STATUS" < "$out"
  if [ $chk -eq 0 ]; then
    dest=$SWEEP/$ph/$lab
  else
    dest=$SWEEP/failed/${ph}-${lab}-attempt${att}-$(date +%H%M%S)
  fi
  mkdir -p "$dest"
  mv -n "$csv" "$log" "$dest"/
  mv -n "$out" "$dest/stage_check.txt"
  [ -f "$js" ] && mv -n "$js" "$dest/stage_result.json"
  [ $hrc -ne 0 ] && say "NOTE harness exit code was $hrc (the stage verdict above is what counts)"
  if [ $chk -eq 0 ]; then say "STAGE-OK $ph $lab -> ${dest#$LOGS/}"; return 0; fi
  say "STAGE-VOID $ph $lab attempt=$att -> kept in ${dest#$LOGS/}"
  return 1
}

do_stage() {  # phase label
  local ph=$1 lab=$2 att
  if [ -f "$SWEEP/$ph/$lab/stage_result.json" ]; then say "STAGE-SKIP $ph $lab (valid result already on disk)"; return 0; fi
  for att in $(seq 1 $MAXATT); do
    run_attempt "$ph" "$lab" "$att" && return 0
    if [ "$att" -lt "$MAXATT" ]; then
      say "STAGE-RETRY $ph $lab: attempt $((att+1)) of $MAXATT on a fresh boot, after a ${SETTLE}s settle pause"
      sleep "$SETTLE"
    fi
  done
  say "CHAIN ABORT: $ph $lab was void on all $MAXATT attempts - stopping for a human"
  return 1
}

ok=1
for ph in off on; do
  say "PHASE $ph begins $(date '+%F %T')"
  for lab in "${LABELS[@]}"; do
    do_stage "$ph" "$lab" || { ok=0; break 2; }
  done
done

valid=$(ls "$SWEEP"/off/*/stage_result.json "$SWEEP"/on/*/stage_result.json 2>/dev/null | wc -l)
say "CHAIN FINISHED $(date '+%F %T')  ok=$ok  valid_stages=$valid/$(( ${#LABELS[@]} * 2 ))"
[ -f "$TOOLS/lu_sweep_table.py" ] && python3 "$TOOLS/lu_sweep_table.py" "$SWEEP" 2>&1 | tee -a "$STATUS"
echo "(window stays open - Ctrl-b d to detach, 'exit' to close)"
exec bash
