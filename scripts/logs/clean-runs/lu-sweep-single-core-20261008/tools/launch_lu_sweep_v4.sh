#!/bin/bash
# Single-core LU sweep, FRESH BOOT PER MEASURED WINDOW, one run per arm.   (2026-10-08, user request)
#
#   9 points  x  2 arms  =  18 stages.  Every stage: reprogram BIT1 -> boot -> stage -> ONE window.
#   OFF and ON go through the SAME harness steps; the only difference is --migrate=<phase>.
#
# Validity gate after every stage (tools/check_lu_stage.py): a VOID run is kept under failed/. The gate judges only
# whether the run is valid, never how big the effect is, so a retry can never be used to pick a nicer number.
# History: v1 (launch_lu_sweep.sh.v1) 2 attempts per stage; v2 (launch_lu_sweep.sh) 3 attempts and a settle pause after
# a silent boot; v3 (launch_lu_sweep_v3.sh, never run) drop-after-3-attempts.
#
# v4 (2026-10-08 04:1x) - the user's policy: "if a run failed, drop it and continue to the next run; after sweeping
# through all configs, try to rerun the failed runs again and populate the table."
#   PASS 1  every stage gets exactly ONE attempt: all OFF stages, then all ON stages. A void attempt is kept under
#           failed/, the stage is DEFERRED, and the chain goes straight on to the next stage (after the settle pause).
#   PASS 2  after the whole list has been swept, every deferred stage gets up to RETRY_ATT more attempts (OFF stages
#           first, then ON), each on a fresh boot. A stage that becomes valid is filled into the table; one that is
#           still void after its retries is GIVEN UP (dropped/<phase>-<label>.txt) and reported as such.
#   Guard   3 failed attempts in a row, in either pass, stop the chain for a human: that points at the board, not at
#           the configurations. Nothing is decided from a measured value, only from how an attempt ended.
#   Phase-order exception (user's instruction): an OFF stage that is only repaired in pass 2 runs after the ON stages.
#           Every window is still the first and only one after a full reprogram, so the history is matched; the stage
#           gets <phase>/<label>/retry_pass.txt and the table flags it.
#   Adoption  If a harness of THIS sweep is already running when this script starts (the previous launcher was stopped
#           by hand to switch policy), it is left alone, waited for, and judged by the same checker as any stage.
#
# Re-running this script resumes: a stage with a valid stage_result.json is skipped; a stage with failed attempts on
# disk and no valid result is treated as deferred (pass 2); a stage with dropped/<phase>-<label>.txt is skipped.
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
RETRY_ATT=2                                     # extra attempts per deferred stage in pass 2
STOP_AFTER_FAILS=3                              # failed attempts in a row that stop the chain
SETTLE=150                                      # seconds to wait before a reprogram that follows a failed attempt: lets the
                                                # board's kernel write back anything dirty to the SD card first

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

consec_fail=0                                    # failed attempts in a row
LAST_FAILED=0                                    # 1 if the previous attempt failed: settle before the next reprogram
DEFERRED=()                                      # "phase|label" of stages that failed in pass 1
ADOPT_PID=""; ADOPT_PH=""; ADOPT_LAB=""; ADOPT_BIT=""; ADOPT_PLAN=""

say() { echo "$@" | tee -a "$STATUS"; }
pre_fail() { say "CHAIN ABORT (preflight): $*"; exit 1; }

nfailed()  { ls -d "$SWEEP"/failed/"${1}-${2}"-attempt* 2>/dev/null | wc -l; }   # phase label -> failed attempts on disk
is_valid() { [ -f "$SWEEP/$1/$2/stage_result.json" ]; }
gave_up()  { [ -f "$SWEEP/dropped/$1-$2.txt" ]; }

# ───────────── judge one finished attempt: checker, file the evidence, say what happened ─────────────
finish_attempt() {  # phase label attempt csv log hrc  -> 0 valid | 1 void, no measured window | 2 void, a window was measured (or the checker itself failed)
  local ph=$1 lab=$2 att=$3 csv=$4 log=$5 hrc=$6 out js dest chk kind=nowindow
  out=$SWEEP/.check_$$.txt; js=$SWEEP/.result_$$.json
  python3 "$TOOLS/check_lu_stage.py" --csv "$csv" --log "$log" --phase "$ph" --label "$lab" \
          --bit "$BIT1" --bit-sha "$BIT1_SHA" --json "$js" > "$out" 2>&1
  chk=$?
  tee -a "$STATUS" < "$out"
  if [ $chk -eq 0 ]; then
    dest=$SWEEP/$ph/$lab
  else
    dest=$SWEEP/failed/${ph}-${lab}-attempt${att}-$(date +%H%M%S)
    # did this attempt ever measure a window? (stage_result.json holds the parsed window counters; empty = none)
    if [ ! -f "$js" ] || python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("counters") else 1)' "$js" 2>/dev/null; then
      kind=measured      # a window exists, or the checker itself did not run
    fi
  fi
  mkdir -p "$dest"
  mv -n "$csv" "$log" "$dest"/
  mv -n "$out" "$dest/stage_check.txt"
  [ -f "$js" ] && mv -n "$js" "$dest/stage_result.json"
  [ "$hrc" != 0 ] && [ "$hrc" != adopted ] && say "NOTE harness exit code was $hrc (the stage verdict above is what counts)"
  if [ $chk -eq 0 ]; then say "STAGE-OK $ph $lab -> ${dest#$LOGS/}"; return 0; fi
  say "STAGE-VOID $ph $lab attempt=$att -> kept in ${dest#$LOGS/}  (kind: $kind)"
  [ "$kind" = nowindow ] && return 1
  return 2
}

# ───────────── one attempt = one fresh boot = one window ─────────────
run_attempt() {  # phase label attempt  -> same codes as finish_attempt
  local ph=$1 lab=$2 att=$3 before after csv log hrc ann
  if [ "$LAST_FAILED" = 1 ]; then
    say "SETTLE ${SETTLE}s before the next reprogram (the previous attempt failed)"
    sleep "$SETTLE"
  fi
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
    say "STAGE-VOID $ph $lab attempt=$att: the harness (exit $hrc) wrote no CSV  (kind: nowindow)"
    return 1
  fi
  csv=$after; log=${csv/lu_runs_/lu_session_}; log=${log%.csv}.log
  finish_attempt "$ph" "$lab" "$att" "$csv" "$log" "$hrc"
}

# after every attempt: keep the streak and the settle flag; return 1 when the streak says the board is the problem
note_outcome() {  # rc phase label
  if [ "$1" -eq 0 ]; then consec_fail=0; LAST_FAILED=0; return 0; fi
  consec_fail=$((consec_fail+1)); LAST_FAILED=1
  if [ $consec_fail -ge $STOP_AFTER_FAILS ]; then
    say "CHAIN ABORT: $consec_fail failed attempts in a row (the last: $2 $3) - that points at the board, not the configurations - stopping for a human"
    return 1
  fi
  return 0
}

in_labels() { local l; for l in "${LABELS[@]}"; do [ "$l" = "$1" ] && return 0; done; return 1; }

# a ps line "pid /usr/bin/expect -- <harness> <args...>" -> ADOPT_*; succeeds only for THIS sweep's harness invocation
parse_rival() {
  local line=$1 harness
  # shellcheck disable=SC2086
  set -- $line
  [ $# -ge 4 ] || return 1
  ADOPT_PID=$1; harness=$4; ADOPT_PH=""; ADOPT_LAB=""; ADOPT_BIT=""; ADOPT_PLAN=""
  shift 4
  while [ $# -gt 0 ]; do
    case "$1" in
      -bench)  ADOPT_LAB=${2:-};  shift ;;
      -phases) ADOPT_PH=${2:-};   shift ;;
      -bit)    ADOPT_BIT=${2:-};  shift ;;
      -plan)   ADOPT_PLAN=${2:-}; shift ;;
    esac
    shift
  done
  [ "$harness" = "$HARNESS" ] && [ "$ADOPT_BIT" = "$BIT1" ] && [ "$ADOPT_PLAN" = lu ] && [ -n "$ADOPT_PH" ] && in_labels "$ADOPT_LAB"
}

adopt_and_finish() {  # waits for the running harness (ADOPT_*) and judges it; returns finish_attempt's code
  local lastlog alog acsv aatt
  lastlog=$(grep -a "^STAGE-LOG $ADOPT_PH $ADOPT_LAB " "$STATUS" | tail -1)
  alog=$(echo "$lastlog" | sed -n 's/.* log=\([^ ]*\) .*/\1/p')
  acsv=$(echo "$lastlog" | sed -n 's/.* csv=\([^ ]*\).*/\1/p')
  if [ -z "$alog" ] || [ ! -f "$alog" ] || [ ! -f "$acsv" ]; then
    pre_fail "cannot adopt the running harness (pid $ADOPT_PID): no usable STAGE-LOG line / files for $ADOPT_PH $ADOPT_LAB"
  fi
  aatt=$(( $(nfailed "$ADOPT_PH" "$ADOPT_LAB") + 1 ))
  say "NOTE $(date '+%F %T') launcher v4 adopted the running harness (pid $ADOPT_PID, $ADOPT_PH $ADOPT_LAB, attempt $aatt, transcript $(basename "$alog")). The previous launcher was stopped by hand to change the retry policy; this stage is judged by the same checker."
  while kill -0 "$ADOPT_PID" 2>/dev/null; do sleep 5; done
  finish_attempt "$ADOPT_PH" "$ADOPT_LAB" "$aatt" "$acsv" "$alog" adopted
}

# ───────────── pass 1: one attempt per stage, failures deferred ─────────────
pass1() {  # returns 1 if the chain must stop
  local ph lab rc
  for ph in off on; do
    say "PHASE $ph begins $(date '+%F %T')"
    for lab in "${LABELS[@]}"; do
      if is_valid "$ph" "$lab"; then say "STAGE-SKIP $ph $lab (valid result already on disk)"; continue; fi
      if gave_up "$ph" "$lab"; then say "STAGE-SKIP $ph $lab (given up earlier, see dropped/$ph-$lab.txt)"; continue; fi
      if [ "$(nfailed "$ph" "$lab")" -gt 0 ]; then
        DEFERRED+=("$ph|$lab")
        say "STAGE-DEFERRED $ph $lab (failed earlier, $(nfailed "$ph" "$lab") attempt(s) on disk; it goes to the retry pass)"
        continue
      fi
      run_attempt "$ph" "$lab" 1; rc=$?
      note_outcome "$rc" "$ph" "$lab" || return 1
      if [ $rc -ne 0 ]; then
        DEFERRED+=("$ph|$lab")
        say "STAGE-DEFERRED $ph $lab: failed once; the chain goes on to the next stage and retries it after the sweep (pass 2)"
      fi
    done
  done
  return 0
}

# ───────────── pass 2: the deferred stages get another go ─────────────
pass2() {  # returns 1 if the chain must stop
  local item ph lab r att rc fixed
  [ ${#DEFERRED[@]} -gt 0 ] || { say "PASS 2 (retry): nothing was deferred"; return 0; }
  say "PASS 2 (retry) begins $(date '+%F %T'): ${#DEFERRED[@]} deferred stage(s): ${DEFERRED[*]}"
  for item in "${DEFERRED[@]}"; do
    ph=${item%%|*}; lab=${item#*|}
    fixed=0
    for r in $(seq 1 $RETRY_ATT); do
      att=$(( $(nfailed "$ph" "$lab") + 1 ))
      say "STAGE-RETRY $ph $lab: retry $r of $RETRY_ATT (attempt $att overall), on a fresh boot"
      run_attempt "$ph" "$lab" "$att"; rc=$?
      note_outcome "$rc" "$ph" "$lab" || return 1
      if [ $rc -eq 0 ]; then
        fixed=1
        echo "validated in the retry pass at $(date '+%F %T'), after $(( $(nfailed "$ph" "$lab") )) failed attempt(s); it ran after the other stages of the sweep" > "$SWEEP/$ph/$lab/retry_pass.txt"
        break
      fi
    done
    if [ $fixed -eq 0 ]; then
      mkdir -p "$SWEEP/dropped"
      { echo "gave up $(date '+%F %T')"
        echo "stage   $ph $lab"
        echo "reason  void on every attempt, including $RETRY_ATT retries in the retry pass; user policy 2026-10-08: drop, continue, retry after the sweep"
        echo "decided from how the attempts ended, not from any measured value"
        echo "attempt files:"; ls -d "$SWEEP"/failed/"${ph}-${lab}"-attempt* 2>/dev/null | sed 's/^/  /'
      } > "$SWEEP/dropped/$ph-$lab.txt"
      say "STAGE-GAVE-UP $ph $lab: still void after $RETRY_ATT retries (dropped/$ph-$lab.txt)"
    fi
  done
  return 0
}

# test hook: `LU_TEST_SOURCE=1 source launch_lu_sweep_v4.sh` loads the functions above and stops (a no-op for a normal run)
[ "${LU_TEST_SOURCE:-}" = 1 ] && return 0

mkdir -p "$SWEEP/off" "$SWEEP/on" "$SWEEP/failed" "$SWEEP/dropped" "$VIV"

# ───────────── preflight: refuse to start on anything that is not exactly as planned ─────────────
[ -f "$BIT1" ]      || pre_fail "bitstream missing: $BIT1"
[ "$(sha256sum "$BIT1" | cut -c1-16)" = "$BIT1_SHA" ] || pre_fail "bitstream sha256 is not $BIT1_SHA"
[ -x "$HARNESS" ]   || pre_fail "harness not executable: $HARNESS"
[ -f "$TOOLS/check_lu_stage.py" ] || pre_fail "checker missing"
RIVAL=$(ps -eo pid=,args= | awk '$2 ~ /(^|\/)expect$/ && $4 ~ /run_(pair|parsec)_session\.exp$/')
if [ -n "$RIVAL" ]; then
  [ "$(printf '%s\n' "$RIVAL" | wc -l)" = 1 ] || pre_fail "more than one measurement session is running"
  parse_rival "$RIVAL" || pre_fail "a measurement session that is not this sweep's owns the board: $RIVAL"
else
  ADOPT_PID=""
fi
PLAN_LIST=$("$HARNESS" "${HARNESS_ARGS[@]}" -list 2>&1)
for lab in "${LABELS[@]}"; do
  echo "$PLAN_LIST" | grep -q "^  $lab " || pre_fail "label $lab is not in the harness plan"
done
[ "$(echo "$PLAN_LIST" | grep -c '^  lu-p')" = "${#LABELS[@]}" ] || pre_fail "the harness plan has a different number of points than this script"

{
  echo "CHAIN-START $(date '+%F %T')  stages=$(( ${#LABELS[@]} * 2 ))  pass1=1 attempt/stage  retry_attempts=$RETRY_ATT  stop_after_fails=$STOP_AFTER_FAILS"
  echo "PROVENANCE bitstream  $BIT1  sha256=$(sha256sum "$BIT1" | cut -d' ' -f1)"
  echo "PROVENANCE harness    $HARNESS  sha256=$(sha256sum "$HARNESS" | cut -d' ' -f1)"
  for f in "$CY"/scripts/ssbc_scripts/lib/*.exp; do echo "PROVENANCE lib        $f  sha256=$(sha256sum "$f" | cut -d' ' -f1)"; done
  echo "PROVENANCE checker    $TOOLS/check_lu_stage.py  sha256=$(sha256sum "$TOOLS/check_lu_stage.py" | cut -d' ' -f1)  (v2)"
  echo "PROVENANCE launcher   $0  sha256=$(sha256sum "$0" | cut -d' ' -f1)  (v4: defer failures, retry after the sweep; SETTLE=${SETTLE}s)"
  echo "PROVENANCE sbc_read   $CY/generators/rocket-chip-inclusive-cache/sw/build/sbc_read  sha256=$(sha256sum "$CY/generators/rocket-chip-inclusive-cache/sw/build/sbc_read" | cut -d' ' -f1)"
  echo "PROVENANCE lu_ncb     $CY/software/parsec-benchmark/staged/lu_ncb  sha256=$(sha256sum "$CY/software/parsec-benchmark/staged/lu_ncb" | cut -d' ' -f1)"
  echo "PROVENANCE git        HEAD=$(git -C "$CY" rev-parse --short HEAD)  (the working tree has uncommitted edits; the shas above are what ran)"
} | tee -a "$STATUS"

ok=1
if [ -n "$ADOPT_PID" ]; then
  adopt_and_finish; rc=$?
  note_outcome "$rc" "$ADOPT_PH" "$ADOPT_LAB" || ok=0
fi
[ $ok -eq 1 ] && { pass1 || ok=0; }
[ $ok -eq 1 ] && { pass2 || ok=0; }

valid=$(ls "$SWEEP"/off/*/stage_result.json "$SWEEP"/on/*/stage_result.json 2>/dev/null | wc -l)
gaveup=$(ls "$SWEEP"/dropped/*.txt 2>/dev/null | wc -l)
say "CHAIN FINISHED $(date '+%F %T')  ok=$ok  valid_stages=$valid/$(( ${#LABELS[@]} * 2 ))  gave_up=$gaveup"
[ -f "$TOOLS/lu_sweep_table.py" ] && python3 "$TOOLS/lu_sweep_table.py" "$SWEEP" 2>&1 | tee -a "$STATUS"
echo "(window stays open - Ctrl-b d to detach, 'exit' to close)"
exec bash
