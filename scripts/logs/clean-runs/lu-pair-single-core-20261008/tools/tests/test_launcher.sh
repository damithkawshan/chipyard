#!/bin/bash
# Host-only test of tools/launch_lu_pair.sh with a FAKE harness. No board, no Vivado.
#
# usage: test_launcher.sh <scratch_dir>      (needs the fixtures that test_check_lupair.py writes into <scratch_dir>/fx)
#
# The launcher under test is a copy of the production one with ONLY these lines changed: PAIR, LOGS, TOOLS (so the real
# checker and table script are used), HARNESS (a fake that drops a fixture CSV + transcript into the fake logs dir),
# SETTLE (1 s) and the final `exec bash` (exit). The diff is printed first so that is checkable.
set -u
SC=$1
HERE=$(cd "$(dirname "$0")/.." && pwd)            # .../tools
PROD=$HERE/launch_lu_pair.sh
FIX=$SC/fx
W=$SC/launch-$$                                  # a fresh working dir per invocation: the launcher RESUMES from valid results on disk
[ -f "$FIX/lupair_session_off_good.log" ] || { echo "run test_check_lupair.py $SC/fx first"; exit 2; }

mkdir -p "$W"
fake=$W/fake_harness.sh
cat > "$fake" <<'EOF'
#!/bin/bash
# fake run_parsec_session.exp: -list prints the plan, otherwise pops the next fixture name from seq.txt and drops it
D=$(cd "$(dirname "$0")" && pwd)
a=("$@"); for ((i=0;i<${#a[@]};i++)); do case "${a[i]}" in -list) list=1;; -bench) lab=${a[i+1]};; -phases) ph=${a[i+1]};; esac; done
if [ -n "${list:-}" ]; then
  echo "plan for -plan lupair  (1 point(s)):"
  echo "  lupair-p1-n512-b32+b128-plru   ->   ./lu_ncb -p1 -n512 -b32 ..."
  exit 0
fi
name=$(head -1 "$D/seq.txt"); sed -i 1d "$D/seq.txt"
[ -n "$name" ] || { echo "fake harness: seq.txt is empty"; exit 3; }
st=$(date +%Y%m%d-%H%M%S)-$RANDOM
cp "$D/fx/lupair_runs_$name.csv"    "$D/logs/lupair_runs_$st.csv"
cp "$D/fx/lupair_session_$name.log" "$D/logs/lupair_session_$st.log"
echo "fake harness: $ph $lab -> fixture $name"
exit 0
EOF
chmod +x "$fake"

mk_launcher() {  # dir
  local d=$1 L=$1/launch_test.sh
  mkdir -p "$d/logs" "$d/pair/tools"
  ln -sfn "$FIX" "$d/fx"
  cp "$fake" "$d/fake_harness.sh"
  sed -e "s|^LOGS=.*|LOGS=$d/logs|" \
      -e "s|^PAIR=.*|PAIR=$d/pair|" \
      -e "s|^TOOLS=.*|TOOLS=$HERE|" \
      -e "s|^HARNESS=.*|HARNESS=$d/fake_harness.sh|" \
      -e "s|^SETTLE=150 |SETTLE=1   |" \
      -e "s|^exec bash\$|exit 0|" "$PROD" > "$L"
  chmod +x "$L"
}

echo "== diff production vs test launcher (only the intended lines may differ):"
mk_launcher "$W/diffcheck"
diff "$PROD" "$W/diffcheck/launch_test.sh" | grep '^[<>]' | cut -c1-110
echo

pass=0; total=0
check() {  # name condition-string
  total=$((total+1))
  if eval "$2"; then pass=$((pass+1)); echo "PASS  $1"; else echo "FAIL  $1   [$2]"; fi
}

run_scn() {  # name seq... ; leaves $d (the scenario dir) and $out
  local name=$1; shift
  d=$W/$name; mk_launcher "$d"; : > "$d/seq.txt"
  for s in "$@"; do echo "$s" >> "$d/seq.txt"; done
  out=$d/out.txt
  bash "$d/launch_test.sh" > "$out" 2>&1; rc=$?
}

# 1. clean: OFF valid, ON valid
run_scn s1_clean off_good on_good
check "s1 clean: two valid stages, exit 0"            "[ $rc -eq 0 ] && grep -q 'valid_stages=2/2' $out && grep -q 'ok=1' $out"
check "s1 clean: OFF ran before ON"                   "[ \$(grep -n 'STAGE-START off' $out | head -1 | cut -d: -f1) -lt \$(grep -n 'STAGE-START on' $out | head -1 | cut -d: -f1) ]"
check "s1 clean: files filed under off/ and on/"      "[ -f $d/pair/off/lupair-p1-n512-b32+b128-plru/stage_result.json ] && [ -f $d/pair/on/lupair-p1-n512-b32+b128-plru/stage_result.json ]"
check "s1 clean: no failed/ attempts"                 "[ -z \"\$(ls $d/pair/failed)\" ]"
check "s1 clean: table script ran (PARTIAL: no solos in the fake tree)" "grep -q 'Single-core LU pair' $out"
check "s1 clean: provenance names the original harness and the lupair copy" "grep -q 'PROVENANCE orig-harn' $out && grep -q 'PROVENANCE harness' $out"

# 2. OFF void once, then valid; ON valid
run_scn s2_retry rc_b_killed off_good on_good
check "s2 retry: finished ok with 2 valid stages"     "[ $rc -eq 0 ] && grep -q 'valid_stages=2/2' $out"
check "s2 retry: one void attempt kept under failed/" "[ \$(ls $d/pair/failed | wc -l) -eq 1 ]"
check "s2 retry: STAGE-RETRY printed, settle used"    "grep -q 'STAGE-RETRY off' $out"
check "s2 retry: the void attempt is named off-...-attempt1" "ls $d/pair/failed | grep -q '^off-lupair-p1-n512-b32+b128-plru-attempt1-'"

# 3. OFF void three times: abort, ON never started
run_scn s3_abort rc_b_killed rc_b_killed rc_b_killed on_good
check "s3 abort: exit 0 but ok=0 and CHAIN ABORT"      "grep -q 'CHAIN ABORT: off' $out && grep -q 'ok=0' $out"
check "s3 abort: three attempts kept, ON never started" "[ \$(ls $d/pair/failed | wc -l) -eq 3 ] && ! grep -q 'STAGE-START on' $out"
check "s3 abort: the ON fixture was not consumed"       "[ \$(wc -l < $d/seq.txt) -eq 1 ]"

# 4. resume: a valid OFF stage on disk is skipped
run_scn s4_resume_a off_good on_good
d4=$W/s4_resume_b; mk_launcher "$d4"; : > "$d4/seq.txt"; echo on_good >> "$d4/seq.txt"
mkdir -p "$d4/pair/off"; cp -r "$d/pair/off/lupair-p1-n512-b32+b128-plru" "$d4/pair/off/"
bash "$d4/launch_test.sh" > "$d4/out.txt" 2>&1; rc4=$?
check "s4 resume: OFF skipped, ON ran, 2 valid"        "[ $rc4 -eq 0 ] && grep -q 'STAGE-SKIP off' $d4/out.txt && grep -q 'STAGE-START on' $d4/out.txt && ! grep -q 'STAGE-START off' $d4/out.txt && grep -q 'valid_stages=2/2' $d4/out.txt"

# 5. preflight: a rival expect on the board is refused (a harmless dummy process whose args look like one)
d5=$W/s5_rival; mk_launcher "$d5"; : > "$d5/seq.txt"
( exec -a "expect -f /x/run_parsec_session.exp" sleep 20 ) & rv=$!
sleep 0.5
bash "$d5/launch_test.sh" > "$d5/out.txt" 2>&1; rc5=$?
kill $rv 2>/dev/null; wait $rv 2>/dev/null
check "s5 rival: refused at preflight, exit 1, no harness call" "[ $rc5 -eq 1 ] && grep -q 'CHAIN ABORT (preflight): another measurement session owns the board' $d5/out.txt && ! grep -q 'STAGE-START' $d5/out.txt"

# 6. a repeat (PAIR_RUN=r2) in the SAME pair dir: it runs its own two stages (run 1's valid results must not make it skip),
#    files them under r2/, and leaves run 1's results and chain_status.txt untouched   (added 2026-10-08, launcher v2)
J=lupair-p1-n512-b32+b128-plru
run_scn s6_run1 off_good on_good
d6=$d
h1=$(cat $d6/pair/off/$J/stage_result.json $d6/pair/on/$J/stage_result.json | sha256sum | cut -c1-16)
l1=$(wc -l < $d6/pair/chain_status.txt)
: > "$d6/seq.txt"; echo off_good >> "$d6/seq.txt"; echo on_good >> "$d6/seq.txt"
PAIR_RUN=r2 bash "$d6/launch_test.sh" > "$d6/out_r2.txt" 2>&1; rc6=$?
check "s6 repeat: exit 0, 2 valid stages, run=r2 in CHAIN-START" "[ $rc6 -eq 0 ] && grep -q 'valid_stages=2/2' $d6/out_r2.txt && grep -q 'run=r2' $d6/out_r2.txt"
check "s6 repeat: not skipped (OFF and ON both started)"       "grep -q 'STAGE-START off' $d6/out_r2.txt && grep -q 'STAGE-START on' $d6/out_r2.txt && ! grep -q 'STAGE-SKIP' $d6/out_r2.txt"
check "s6 repeat: stages and status filed under r2/"           "[ -f $d6/pair/r2/off/$J/stage_result.json ] && [ -f $d6/pair/r2/on/$J/stage_result.json ] && [ -f $d6/pair/r2/chain_status.txt ]"
check "s6 repeat: run 1's results and chain_status.txt untouched" "[ \"\$(cat $d6/pair/off/$J/stage_result.json $d6/pair/on/$J/stage_result.json | sha256sum | cut -c1-16)\" = $h1 ] && [ \$(wc -l < $d6/pair/chain_status.txt) -eq $l1 ]"
check "s6 repeat: OFF started before ON"                       "[ \$(grep -n 'STAGE-START off' $d6/out_r2.txt | head -1 | cut -d: -f1) -lt \$(grep -n 'STAGE-START on' $d6/out_r2.txt | head -1 | cut -d: -f1) ]"
check "s6 repeat: no failed/ attempts under r2/"               "[ -z \"\$(ls $d6/pair/r2/failed)\" ]"

echo; echo "$pass of $total launcher checks passed"
[ $pass -eq $total ]
