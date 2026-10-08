#!/bin/bash
# Host-only test of tools/launch_pairs.sh with a FAKE harness. No board, no Vivado.
#
# usage: test_launch_pairs.sh <scratch_dir>     (needs <scratch_dir>/fxs from `python3 make_fixtures.py <scratch_dir>/fxs`)
#
# The launcher under test is a copy of the production one with ONLY these lines changed: LOGS, SEARCH (a scratch tree),
# TOOLS (the real tools dir, so the real checker is used), HARNESS (a fake that drops a fixture CSV + transcript into the fake
# logs dir), PAIR_HARNESS_SHA (the fake's), SETTLE (1 s), the final `exec bash` (exit) and the two live-process guards (their
# patterns are renamed so a REAL measurement session running on this host does not trip them). The diff is printed first.
set -u
SC=$1
HERE=$(cd "$(dirname "$0")/.." && pwd)                                            # .../lu-pair-search-20261008/tools
PROD=$HERE/launch_pairs.sh
REAL_TOOLS=/home/damith/Research/repos/chipyard_performance_eval/chipyard/scripts/logs/clean-runs/lu-pair-single-core-20261008/tools
FIX=$SC/fxs
W=$SC/lp-$$                                                                        # fresh working dir per invocation
[ -f "$FIX/lupair_session_off_64_64.log" ] || { echo "run: python3 make_fixtures.py $SC/fxs first"; exit 2; }
mkdir -p "$W"

fake=$W/fake_harness.sh
cat > "$fake" <<'EOF'
#!/bin/bash
# fake run_parsec_session.exp: -list prints the plan for -pair-b, otherwise pops the next fixture name from seq.txt and drops it
D=$(cd "$(dirname "$0")" && pwd)
a=("$@"); for ((i=0;i<${#a[@]};i++)); do case "${a[i]}" in -list) list=1;; -pair-b) pb=${a[i+1]};; -bench) lab=${a[i+1]};; -phases) ph=${a[i+1]};; esac; done
if [ -n "${list:-}" ]; then
  echo "plan for -plan lupair  (1 point(s)):"
  echo "  lupair-p1-n512-b${pb%,*}+b${pb#*,}-plru   ->   ./lu_ncb ..."
  exit 0
fi
name=$(head -1 "$D/seq.txt"); sed -i 1d "$D/seq.txt"
[ -n "$name" ] || { echo "fake harness: seq.txt is empty"; exit 3; }
echo "$ph $lab $pb" >> "$D/calls.txt"
st=$(date +%Y%m%d-%H%M%S)-$RANDOM
cp "$D/fxs/lupair_runs_$name.csv"    "$D/logs/lupair_runs_$st.csv"
cp "$D/fxs/lupair_session_$name.log" "$D/logs/lupair_session_$st.log"
echo "fake harness: $ph $lab ($pb) -> fixture $name"
exit 0
EOF
chmod +x "$fake"
FAKESHA=$(sha256sum "$fake" | cut -c1-12)

mk_launcher() {  # dir
  local d=$1 L=$1/launch_test.sh
  mkdir -p "$d/logs" "$d/search"
  ln -sfn "$FIX" "$d/fxs"
  cp "$fake" "$d/fake_harness.sh"
  sed -e "s|^LOGS=.*|LOGS=$d/logs|" \
      -e "s|^SEARCH=.*|SEARCH=$d/search|" \
      -e "s|^TOOLS=.*|TOOLS=$REAL_TOOLS     # the real tools dir (checker)|" \
      -e "s|^HARNESS=.*|HARNESS=$d/fake_harness.sh|" \
      -e "s|^PAIR_HARNESS_SHA=.*|PAIR_HARNESS_SHA=$FAKESHA|" \
      -e "s|^SETTLE=150 |SETTLE=1   |" \
      -e "s|^exec bash\$|exit 0|" \
      -e "s|run_(pair\|parsec)_session|run_TESTRIVAL_session|" \
      -e "s|picocom\.\*ttyUSB|picocom.*ttyTEST|" "$PROD" > "$L"
  chmod +x "$L"
}

echo "== diff production vs test launcher (only the intended lines may differ):"
mk_launcher "$W/diffcheck"
diff "$PROD" "$W/diffcheck/launch_test.sh" | grep '^[<>]' | cut -c1-120
echo

pass=0; total=0
check() { total=$((total+1)); if eval "$2"; then pass=$((pass+1)); echo "PASS  $1"; else echo "FAIL  $1   [$2]"; fi; }

run_scn() {  # name "STAGES" seq...      leaves $d (scenario dir), $out, $rc
  local name=$1 stages=$2; shift 2
  d=$W/$name; mk_launcher "$d"; : > "$d/seq.txt"; : > "$d/calls.txt"
  for s in "$@"; do echo "$s" >> "$d/seq.txt"; done
  out=$d/out.txt
  STAGES="$stages" bash "$d/launch_test.sh" > "$out" 2>&1; rc=$?
}
S=search

# 1. clean: three stages, OFF before ON, files filed by label and phase
run_scn s1_clean "off:64,64 off:32,32 on:64,64" off_64_64 off_32_32 on_64_64
check "s1 clean: three valid stages, exit 0"          "[ $rc -eq 0 ] && grep -q 'valid_stages=3/3' $out && grep -q 'ok=1' $out"
check "s1 clean: harness called in the listed order"  "[ \"\$(cat $d/calls.txt | tr '\n' '|')\" = 'off lupair-p1-n512-b64+b64-plru 64,64|off lupair-p1-n512-b32+b32-plru 32,32|on lupair-p1-n512-b64+b64-plru 64,64|' ]"
check "s1 clean: stage_result.json under off/ and on/" "[ -f $d/$S/off/lupair-p1-n512-b64+b64-plru/stage_result.json ] && [ -f $d/$S/off/lupair-p1-n512-b32+b32-plru/stage_result.json ] && [ -f $d/$S/on/lupair-p1-n512-b64+b64-plru/stage_result.json ]"
check "s1 clean: no failed/ attempts"                  "[ -z \"\$(ls $d/$S/failed)\" ]"
check "s1 clean: provenance printed"                   "grep -q 'PROVENANCE harness' $out && grep -q 'PROVENANCE checker' $out && grep -q 'PROVENANCE launcher' $out"

# 2. one void attempt (program b killed), then valid
run_scn s2_retry "off:64,64" rc_b_killed_64_64 off_64_64
check "s2 retry: ok with 1 valid stage"                "[ $rc -eq 0 ] && grep -q 'valid_stages=1/1' $out"
check "s2 retry: one void attempt kept, named by phase and label" "[ \$(ls $d/$S/failed | wc -l) -eq 1 ] && ls $d/$S/failed | grep -q '^off-lupair-p1-n512-b64+b64-plru-attempt1-'"
check "s2 retry: STAGE-RETRY printed"                  "grep -q 'STAGE-RETRY off lupair-p1-n512-b64+b64-plru' $out"

# 3. three void attempts: chain stops, the next stage is never started
run_scn s3_abort "off:64,64 off:32,32" rc_b_killed_64_64 rc_b_killed_64_64 rc_b_killed_64_64 off_32_32
check "s3 abort: CHAIN ABORT and ok=0"                 "grep -q 'CHAIN ABORT: off lupair-p1-n512-b64+b64-plru' $out && grep -q 'ok=0' $out"
check "s3 abort: 3 attempts kept, next stage not started" "[ \$(ls $d/$S/failed | wc -l) -eq 3 ] && [ \$(wc -l < $d/calls.txt) -eq 3 ] && [ \$(wc -l < $d/seq.txt) -eq 1 ]"

# 4. resume: a valid OFF stage on disk is skipped
run_scn s4a "off:64,64" off_64_64
d4=$W/s4b; mk_launcher "$d4"; : > "$d4/seq.txt"; : > "$d4/calls.txt"; echo off_32_32 >> "$d4/seq.txt"
mkdir -p "$d4/$S/off"; cp -r "$d/$S/off/lupair-p1-n512-b64+b64-plru" "$d4/$S/off/"
STAGES="off:64,64 off:32,32" bash "$d4/launch_test.sh" > "$d4/out.txt" 2>&1; rc4=$?
check "s4 resume: 64,64 skipped, 32,32 ran, 2 valid"   "[ $rc4 -eq 0 ] && grep -q 'STAGE-SKIP off lupair-p1-n512-b64+b64-plru' $d4/out.txt && [ \$(wc -l < $d4/calls.txt) -eq 1 ] && grep -q 'valid_stages=2/2' $d4/out.txt"

# 5. an ON stage later, with its OFF stage valid on disk from before: accepted; without it: refused
d5=$W/s5; mk_launcher "$d5"; : > "$d5/seq.txt"; : > "$d5/calls.txt"; echo on_64_64 >> "$d5/seq.txt"
mkdir -p "$d5/$S/off"; cp -r "$d4/$S/off/lupair-p1-n512-b64+b64-plru" "$d5/$S/off/"
STAGES="on:64,64" bash "$d5/launch_test.sh" > "$d5/out.txt" 2>&1; rc5=$?
check "s5 ON with a valid OFF on disk: accepted"       "[ $rc5 -eq 0 ] && grep -q 'valid_stages=1/1' $d5/out.txt"
run_scn s5b "on:32,32" on_32_32
check "s5 ON without any OFF stage: refused, no harness call" "[ $rc -eq 1 ] && grep -q 'ON stage for 32,32 has no OFF stage' $out && [ ! -s $d/calls.txt ]"
run_scn s5c "on:64,64 off:64,64" on_64_64 off_64_64
check "s5 OFF after ON in the list: refused"           "[ $rc -eq 1 ] && grep -q 'all OFF stages come before any ON stage' $out && [ ! -s $d/calls.txt ]"
run_scn s5d "off:64,64 on:64,64" off_64_64 on_64_64
check "s5 OFF then ON of the same pair in one list: accepted" "[ $rc -eq 0 ] && grep -q 'valid_stages=2/2' $out"

# 6. input validation
run_scn s6a ""
check "s6 empty STAGES: refused"                       "[ $rc -eq 1 ] && grep -q 'STAGES is empty' $out"
run_scn s6b "off:64" off_64_64
check "s6 malformed stage: refused"                    "[ $rc -eq 1 ] && grep -q \"bad stage 'off:64'\" $out"

# 7. a rival expect on the board is refused (a harmless dummy process whose args look like one)
d7=$W/s7; mk_launcher "$d7"; : > "$d7/seq.txt"; : > "$d7/calls.txt"
( exec -a "expect -f /x/run_TESTRIVAL_session.exp" sleep 20 ) & rv=$!
sleep 0.5
STAGES="off:64,64" bash "$d7/launch_test.sh" > "$d7/out.txt" 2>&1; rc7=$?
kill $rv 2>/dev/null; wait $rv 2>/dev/null
check "s7 rival: refused at preflight, exit 1, no harness call" "[ $rc7 -eq 1 ] && grep -q 'another measurement session owns the board' $d7/out.txt && [ ! -s $d7/calls.txt ]"

echo; echo "$pass of $total launcher checks passed"
[ $pass -eq $total ]
