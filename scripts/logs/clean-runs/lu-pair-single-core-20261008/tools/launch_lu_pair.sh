#!/bin/bash
# Single-core LU PAIR test (two lu_ncb running together on the one core), FRESH BOOT PER MEASURED WINDOW.   (2026-10-08)
#
#   1 pair x 2 arms = 2 stages.  Every stage: reprogram BIT1 -> boot -> stage -> ONE window.
#   The OFF stage first, then the ON stage (phase order is absolute). OFF and ON go through the SAME harness steps;
#   the only difference is --migrate=<phase>. The harness is tools/run_parsec_session.exp, a copy of the sweep's
#   scripts/ssbc_scripts/run_parsec_session.exp with a -plan lupair added (see its header and PLAN.md); the solo
#   windows this test is compared with are the clean LU sweep's, taken with the original harness.
#
# Validity gate after every stage (tools/check_lupair_stage.py, adapted from the sweep's check_lu_stage.py v2): a VOID
# run is kept under failed/, the stage is retried on a fresh boot after a SETTLE pause, and the chain STOPS when MAXATT
# attempts are void. The gate judges only whether the run is valid, never how big the effect is, so a retry cannot pick
# a nicer number. (Same retry shape as the sweep's launcher v2: 3 attempts, 150 s settle.)
#
# Re-running this script resumes: a stage that already has a valid stage_result.json is skipped.
# PAIR_RUN=<tag> (v2, 2026-10-08) runs the same pair AGAIN as a repeat: its stages, failures, results and status go to
# $PAIR/<tag>/ (off/ on/ failed/ results/ chain_status.txt), so run 1 is never skipped, overwritten or appended to. Unset =
# the run-1 layout (launch_lu_pair.sh.v1 is the file run 1 used; v2 differs from it only by the OUT/SWEEP/PAIR_RUN lines).
# Never passes -allow-*, never uses --reset-all. Does not edit the original harness. Does not commit anything.
set -u

CY=/home/damith/Research/repos/chipyard_performance_eval/chipyard
BIT1=$CY/fpga/bitstream_storage/FPGASingleRocketVCU118L18K256K8WL2ConfigSBCPLRU-256KB-8way-candidate013-2026-10-01-2026-10-01.bit
BIT1_SHA=5ace41250e7c5141                       # first 16 hex of sha256, recorded 2026-10-07
ORIG_HARNESS_SHA=b13d93e768b045598059            # first 20 hex of the ORIGINAL run_parsec_session.exp, recorded 2026-10-08
LOGS=$CY/scripts/logs
PAIR=$LOGS/clean-runs/lu-pair-single-core-20261008
PAIR_RUN=${PAIR_RUN:-}                          # unset = run 1; "r2" = the repeat, filed under $PAIR/r2/
OUT=$PAIR${PAIR_RUN:+/$PAIR_RUN}                # where this invocation's off/ on/ failed/ results/ chain_status.txt live
SWEEP=$LOGS/clean-runs/lu-sweep-single-core-20261008   # the solo references the table script compares the pair with
TOOLS=$PAIR/tools
HARNESS=$TOOLS/run_parsec_session.exp
ORIG_HARNESS=$CY/scripts/ssbc_scripts/run_parsec_session.exp
STATUS=$OUT/chain_status.txt
VIV=$PAIR/vivado                                # cwd of every harness call: Vivado's journals land here
MAXATT=3
SETTLE=150                                      # seconds to wait before a retry: lets the board's kernel write
                                                # back anything dirty to the SD card before the FPGA is reset

LABELS=(lupair-p1-n512-b32+b128-plru)
HARNESS_ARGS=(-plan lupair -bit "$BIT1" -policy plru -pair-n 512 -pair-b 32,128)

mkdir -p "$OUT/off" "$OUT/on" "$OUT/failed" "$OUT/results" "$VIV"
say() { echo "$@" | tee -a "$STATUS"; }

# ───────────── preflight: refuse to start on anything that is not exactly as planned ─────────────
pre_fail() { say "CHAIN ABORT (preflight): $*"; exit 1; }
[ -f "$BIT1" ]      || pre_fail "bitstream missing: $BIT1"
[ "$(sha256sum "$BIT1" | cut -c1-16)" = "$BIT1_SHA" ] || pre_fail "bitstream sha256 is not $BIT1_SHA"
[ -x "$HARNESS" ]   || pre_fail "harness not executable: $HARNESS"
[ "$(sha256sum "$ORIG_HARNESS" | cut -c1-20)" = "$ORIG_HARNESS_SHA" ] || pre_fail "the ORIGINAL harness changed since this test was planned (sha256 is not $ORIG_HARNESS_SHA...)"
[ -f "$TOOLS/check_lupair_stage.py" ] || pre_fail "checker missing"
[ -f "$TOOLS/lu_pair_table.py" ]      || pre_fail "table script missing"
if ps -eo args= | grep -E '^[^ ]*expect( |$).*run_(pair|parsec)_session' | grep -v grep >/dev/null; then
  pre_fail "another measurement session owns the board"
fi
if ps -eo args= | grep -E 'picocom.*ttyUSB' | grep -v grep >/dev/null; then
  pre_fail "a picocom already holds the serial port"
fi
PLAN_LIST=$("$HARNESS" "${HARNESS_ARGS[@]}" -list 2>&1)
for lab in "${LABELS[@]}"; do
  echo "$PLAN_LIST" | grep -q "^  $lab " || pre_fail "label $lab is not in the harness plan"
done
[ "$(echo "$PLAN_LIST" | grep -c '^  lupair-p')" = "${#LABELS[@]}" ] || pre_fail "the harness plan has a different number of points than this script"

{
  echo "CHAIN-START $(date '+%F %T')  stages=$(( ${#LABELS[@]} * 2 ))  retries<=$((MAXATT-1))  run=${PAIR_RUN:-run1}  out=${OUT#$LOGS/}"
  echo "PROVENANCE bitstream  $BIT1  sha256=$(sha256sum "$BIT1" | cut -d' ' -f1)"
  echo "PROVENANCE harness    $HARNESS  sha256=$(sha256sum "$HARNESS" | cut -d' ' -f1)  (the lupair copy)"
  echo "PROVENANCE orig-harn  $ORIG_HARNESS  sha256=$(sha256sum "$ORIG_HARNESS" | cut -d' ' -f1)  (unchanged; the copy's diff against it is in PLAN.md)"
  for f in "$CY"/scripts/ssbc_scripts/lib/*.exp; do echo "PROVENANCE lib        $f  sha256=$(sha256sum "$f" | cut -d' ' -f1)"; done
  echo "PROVENANCE checker    $TOOLS/check_lupair_stage.py  sha256=$(sha256sum "$TOOLS/check_lupair_stage.py" | cut -d' ' -f1)"
  echo "PROVENANCE launcher   $0  sha256=$(sha256sum "$0" | cut -d' ' -f1)  (MAXATT=$MAXATT SETTLE=${SETTLE}s)"
  echo "PROVENANCE sbc_read   $CY/generators/rocket-chip-inclusive-cache/sw/build/sbc_read  sha256=$(sha256sum "$CY/generators/rocket-chip-inclusive-cache/sw/build/sbc_read" | cut -d' ' -f1)"
  echo "PROVENANCE lu_ncb     $CY/software/parsec-benchmark/staged/lu_ncb  sha256=$(sha256sum "$CY/software/parsec-benchmark/staged/lu_ncb" | cut -d' ' -f1)"
  echo "PROVENANCE git        HEAD=$(git -C "$CY" rev-parse --short HEAD)  (the working tree has uncommitted edits; the shas above are what ran)"
} | tee -a "$STATUS"

# ───────────── one attempt = one fresh boot = one window ─────────────
run_attempt() {  # phase label attempt  -> 0 valid, 1 void
  local ph=$1 lab=$2 att=$3 before after csv log out js dest hrc chk ann
  before=$(ls -t "$LOGS"/lupair_runs_*.csv 2>/dev/null | head -1)
  say "STAGE-START $ph $lab attempt=$att $(date '+%F %T')"
  # say where the transcript is the moment the harness creates it
  ( for i in $(seq 1 180); do
      n=$(ls -t "$LOGS"/lupair_runs_*.csv 2>/dev/null | head -1)
      if [ -n "$n" ] && [ "$n" != "$before" ]; then
        lg=${n/lupair_runs_/lupair_session_}; lg=${lg%.csv}.log
        say "STAGE-LOG $ph $lab attempt=$att log=$lg csv=$n"; break
      fi
      sleep 1
    done ) &
  ann=$!
  ( cd "$VIV" && "$HARNESS" "${HARNESS_ARGS[@]}" -bench "$lab" -phases "$ph" -repeat 1 )
  hrc=$?
  wait "$ann" 2>/dev/null
  after=$(ls -t "$LOGS"/lupair_runs_*.csv 2>/dev/null | head -1)
  if [ -z "$after" ] || [ "$after" = "$before" ]; then
    say "STAGE-VOID $ph $lab attempt=$att: the harness (exit $hrc) wrote no CSV"
    return 1
  fi
  csv=$after; log=${csv/lupair_runs_/lupair_session_}; log=${log%.csv}.log
  out=$OUT/.check_$$.txt; js=$OUT/.result_$$.json
  python3 "$TOOLS/check_lupair_stage.py" --csv "$csv" --log "$log" --phase "$ph" --label "$lab" \
          --bit "$BIT1" --bit-sha "$BIT1_SHA" --json "$js" > "$out" 2>&1
  chk=$?
  tee -a "$STATUS" < "$out"
  if [ $chk -eq 0 ]; then
    dest=$OUT/$ph/$lab
  else
    dest=$OUT/failed/${ph}-${lab}-attempt${att}-$(date +%H%M%S)
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
  if [ -f "$OUT/$ph/$lab/stage_result.json" ]; then say "STAGE-SKIP $ph $lab (valid result already on disk)"; return 0; fi
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

valid=$(ls "$OUT"/off/*/stage_result.json "$OUT"/on/*/stage_result.json 2>/dev/null | wc -l)
say "CHAIN FINISHED $(date '+%F %T')  ok=$ok  valid_stages=$valid/$(( ${#LABELS[@]} * 2 ))"
python3 "$TOOLS/lu_pair_table.py" "$OUT" "$SWEEP" 2>&1 | tee -a "$STATUS"
echo "(window stays open - Ctrl-b d to detach, 'exit' to close)"
exec bash
