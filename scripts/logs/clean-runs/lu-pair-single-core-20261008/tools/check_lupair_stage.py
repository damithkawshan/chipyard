#!/usr/bin/env python3
"""Per-stage VALIDITY gate for the single-core LU-pair test (tools/run_parsec_session.exp -plan lupair).

usage: check_lupair_stage.py --csv F --log F --phase off|on --label LABEL --bit PATH --bit-sha HEX16 [--json OUT]

Adapted from check_lu_stage.py v2 (the single-LU sweep's gate); every rule of v2 is kept (one reprogram on the right
file, one boot, one CPU, no kernel crash, the workqueue-lockup placement rule, one measured command, one window, the
counter identities, the hardware read-back of the switch and policy) and the pair-specific rules are added:

  - the measured command is exactly the two-lu_ncb command of the plan (compared with all whitespace removed);
  - "PAIR-RC a=0 b=0" appears exactly once: both programs exited 0;
  - after the window both LU reports were printed: exactly two, the first with the first block size and the second with
    the second, both for the requested matrix size and one processor;
  - the two programs really ran at the same time: overlap fraction from the reports' own Start / Overall-finish times
    (microseconds, one clock) >= 0.5 (void below, as TASK 015 section 8 does for pairs); a warning below 0.9.

Exit 0 VALID / 1 VOID / 2 usage. Only the validity of the RUN is judged. Nothing here looks at the size of the effect,
so a retry can never be used to pick a nicer number. The CSV is read by column NAME, the window line by key=. The
transcript has binary bytes, so it is decoded with errors="replace".
"""
import argparse, csv, hashlib, json, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("--csv", required=True)
ap.add_argument("--log", required=True)
ap.add_argument("--phase", required=True, choices=["off", "on"])
ap.add_argument("--label", required=True)
ap.add_argument("--bit", required=True)
ap.add_argument("--bit-sha", required=True)
ap.add_argument("--json", default="")
a = ap.parse_args()

mm = re.fullmatch(r"lupair-p(\d+)-n(\d+)-b(\d+)\+b(\d+)-(\w+)", a.label)
if not mm:
    print("usage error: label '%s' is not lupair-p<P>-n<N>-b<BA>+b<BB>-<policy>" % a.label)
    sys.exit(2)
exp_p, exp_n, exp_ba, exp_bb, exp_pol = mm.groups()

fails, warns = [], []
oks = []


def need(cond, ok_msg, fail_msg):
    (oks if cond else fails).append(ok_msg if cond else fail_msg)


def warn(msg):
    warns.append(msg)


# ───────────────────────── CSV (by column NAME) ─────────────────────────
rows = list(csv.DictReader(open(a.csv)))
need(len(rows) == 1, "CSV has exactly 1 data row", "CSV has %d data rows, expected exactly 1" % len(rows))
r = rows[0] if rows else {}


def civ(k):
    v = r.get(k, "")
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


need(r.get("status") == "OK", "status=OK", "status=%s (not OK)" % r.get("status"))
need(r.get("rc") == "0", "rc=0", "rc=%s (the shell did not exit 0: a program failed or the harness got no code)" % r.get("rc"))
need(r.get("label") == a.label, "label matches", "label %s != %s" % (r.get("label"), a.label))
need(r.get("migrate") == a.phase, "CSV migrate=%s" % a.phase, "CSV migrate=%s, stage is %s" % (r.get("migrate"), a.phase))
need(r.get("policy") == exp_pol, "policy=%s" % exp_pol, "policy=%s, expected %s" % (r.get("policy"), exp_pol))
exp_b = "%s+%s" % (exp_ba, exp_bb)
need((r.get("p"), r.get("n"), r.get("b")) == (exp_p, exp_n, exp_b), "p/n/b = %s/%s/%s" % (exp_p, exp_n, exp_b),
     "p/n/b = %s/%s/%s, expected %s/%s/%s" % (r.get("p"), r.get("n"), r.get("b"), exp_p, exp_n, exp_b))

# ───────────────────────── transcript ─────────────────────────
raw = open(a.log, "rb").read().decode("utf-8", errors="replace")
txt = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw).replace("\r", "")

# exactly one reprogram, on the right file, which has not changed
progs = re.findall(r"^spawn bash \S*programFPGA\.sh (\S+)", txt, re.M)
need(len(progs) == 1, "exactly 1 FPGA programming", "%d FPGA programmings in the transcript (need exactly 1)" % len(progs))
if progs:
    need(progs[0] == a.bit, "programmed the requested bitstream", "programmed %s, expected %s" % (progs[0], a.bit))
need("FPGA programming complete!" in txt, "Vivado reported 'programming complete'", "no 'FPGA programming complete!' line")
sha = hashlib.sha256(open(a.bit, "rb").read()).hexdigest()
need(sha.startswith(a.bit_sha), "bitstream sha256 %s... matches" % sha[:16], "bitstream sha256 %s... != expected %s" % (sha[:16], a.bit_sha))

boots = re.findall(r"^\[\s*0\.000000\] Linux version", txt, re.M)
need(len(boots) == 1, "exactly 1 Linux boot", "%d Linux boots in the transcript (need exactly 1)" % len(boots))
need(len(re.findall(r"smp: Brought up 1 node, 1 CPU", txt)) == 1, "single core (1 CPU)", "did not read 'Brought up 1 node, 1 CPU' exactly once")
# A kernel crash anywhere voids the run. "BUG: workqueue lockup" is NOT a crash (see check_lu_stage.py v2): the
# watchdog prints it while the staging `sync` waits for the slow SD card. Placement is judged below.
crash = re.search(r"Kernel panic|Oops:|Unable to handle kernel", txt)
other_bug = sorted({m.group(0)[:80] for m in re.finditer(r"BUG:[^\n]*", txt) if "workqueue lockup" not in m.group(0)})
need(not crash and not other_bug, "no kernel panic / oops / BUG (workqueue-lockup lines are judged by position below)",
     "kernel panic / oops / BUG in the transcript: %s" % (crash.group(0) if crash else other_bug[:2]))
bang = [l for l in txt.split("\n") if l.startswith("!!!")]
need(not bang, "no harness '!!!' errors", "harness errors: %s" % " | ".join(bang[:3]))


# Exactly one measured command, and it is the one this stage asked for. The board's tty echo wraps a long line at ~80
# columns mid-command, so compare with ALL whitespace removed. A missing echo is a hard failure, not a warning.
def squash(s):
    return re.sub(r"\s+", "", s)


INNER = ("./lu_ncb -p%s -n%s -b%s >a.out 2>a.err & PA=$! ; ./lu_ncb -p%s -n%s -b%s >b.out 2>b.err & PB=$! ; "
         "wait $PA ; RA=$? ; wait $PB ; RB=$? ; echo PAIR-RC a=$RA b=$RB ; test $RA -eq 0 && test $RB -eq 0 2> wl.err"
         % (exp_p, exp_n, exp_ba, exp_p, exp_n, exp_bb))
cmds = {(sw, pol, squash(c)) for sw, pol, c in
        re.findall(r"--migrate=(on|off) --policy=(\w+) --zero -- sh -c '([^']*)'", txt)}
want = (a.phase, exp_pol, squash(INNER))
need(cmds == {want}, "the only measured command is migrate=%s, the two-lu_ncb command (b%s + b%s, n%s)" % (a.phase, exp_ba, exp_bb, exp_n),
     "measured command(s) in the transcript %s, expected exactly %s" % (sorted(cmds), want))

# exactly one window line, one workload rc, one PAIR-RC with both codes 0
wlines = sorted({l for l in txt.split("\n") if "[SBC-WINDOW]" in l and "migrations=" in l})
need(len(wlines) == 1, "exactly 1 [SBC-WINDOW] line", "%d distinct [SBC-WINDOW] lines (need exactly 1)" % len(wlines))
rcs = re.findall(r"workload rc=(\d+)", txt)
need(rcs == ["0"], "workload rc=0 seen once", "workload rc lines: %s (need exactly ['0'])" % rcs)
prc = re.findall(r"PAIR-RC a=(\d+) b=(\d+)", txt)
need(prc == [("0", "0")], "PAIR-RC a=0 b=0 seen once (both programs exited 0)", "PAIR-RC lines: %s (need exactly [('0', '0')])" % prc)

# workqueue-lockup watchdog lines, judged by where they sit relative to the measured window
lock = [m.start() for m in re.finditer(r"BUG: workqueue lockup", txt)]
cm = re.search(r"--migrate=(?:on|off) --policy=\w+ --zero -- sh -c '", txt)
if not lock:
    oks.append("no workqueue-lockup lines in the transcript")
elif cm is None or not wlines:
    fails.append("workqueue-lockup line(s) in the transcript and the measured window could not be located")
else:
    t_cmd, t_win = cm.start(), txt.index(wlines[0])
    inside = [p for p in lock if t_cmd <= p <= t_win]
    need(not inside, "no workqueue lockup while the window was open",
         "workqueue lockup printed WHILE the window was open (%d line(s))" % len(inside))
    pre = [p for p in lock if p < t_cmd]
    post = [p for p in lock if p > t_win]
    if pre:
        warn("%d 'BUG: workqueue lockup' line(s) before the measured command (staging: the `sync` to the slow SD card "
             "blocked > 30 s); none between the measured command and the window line" % len(pre))
    if post:
        warn("%d 'BUG: workqueue lockup' line(s) after the window line (cannot affect the window)" % len(post))

win = {}
if wlines:
    win = {k: int(v) for k, v in re.findall(r"\b([A-Za-z][A-Za-z0-9_]*)=(-?\d+)", wlines[0])}
    i = txt.index(wlines[0])
    block = txt[i:i + 1500]
    sm = re.search(r"migrate\s*:\s*(ON|OFF)", block)
    pm = re.search(r"policy\s*:\s*(\w+)", block)
    need(bool(sm) and sm.group(1) == a.phase.upper(), "hardware read-back migrate=%s" % a.phase.upper(),
         "hardware read-back migrate=%s, stage is %s" % (sm.group(1) if sm else "MISSING", a.phase.upper()))
    need(bool(pm) and pm.group(1) == exp_pol, "hardware read-back policy=%s" % exp_pol,
         "hardware read-back policy=%s, expected %s" % (pm.group(1) if pm else "MISSING", exp_pol))

# ───────────────────────── the two LU reports (printed after the window, by post_window) ─────────────────────────
reports = []
overlap = None
if wlines:
    after = txt[txt.index(wlines[0]):]
    pm_ = re.search(r"cat a\.out b\.out a\.err b\.err", after)
    seg = after[pm_.end():] if pm_ else ""
    need(pm_ is not None, "the post-window report command is in the transcript", "the post-window 'cat a.out b.out ...' command was not found")
    for chunk in re.split(r"(?=Blocked Dense LU Factorization)", seg):
        if "Element Blocks" not in chunk:
            continue
        g = lambda pat: re.search(pat, chunk)
        mx, pr, bl = g(r"(\d+) by (\d+) Matrix"), g(r"(\d+) Processors"), g(r"(\d+) by (\d+) Element Blocks")
        st, fi, tw = g(r"Start time\s*:\s*(\d+)"), g(r"Overall finish time\s*:\s*(\d+)"), g(r"Total time without initialization\s*:\s*(\d+)")
        if not all([mx, pr, bl, st, fi, tw]):
            reports.append({"incomplete": True})
            continue
        reports.append({"matrix": int(mx.group(1)), "procs": int(pr.group(1)), "block": int(bl.group(1)),
                        "start_us": int(st.group(1)), "finish_us": int(fi.group(1)), "total_us": int(tw.group(1))})
    need(len(reports) == 2, "exactly 2 LU reports were printed", "%d LU reports after the window (need exactly 2)" % len(reports))
    if len(reports) == 2 and not any(x.get("incomplete") for x in reports):
        ra, rb = reports
        need((ra["block"], rb["block"]) == (int(exp_ba), int(exp_bb)),
             "report 1 is block %s, report 2 is block %s (a.out then b.out)" % (exp_ba, exp_bb),
             "report blocks are %s then %s, expected %s then %s" % (ra["block"], rb["block"], exp_ba, exp_bb))
        need(ra["matrix"] == int(exp_n) and rb["matrix"] == int(exp_n), "both reports are %sx%s matrices" % (exp_n, exp_n),
             "matrix sizes %s / %s, expected %s" % (ra["matrix"], rb["matrix"], exp_n))
        need(ra["procs"] == 1 and rb["procs"] == 1, "both reports say 1 processor", "processor counts %s / %s, expected 1" % (ra["procs"], rb["procs"]))
        lo, hi = max(ra["start_us"], rb["start_us"]), min(ra["finish_us"], rb["finish_us"])
        span = max(ra["finish_us"], rb["finish_us"]) - min(ra["start_us"], rb["start_us"])
        overlap = (max(0, hi - lo) / span) if span > 0 else 0.0
        need(overlap >= 0.5, "overlap fraction %.3f (>= 0.5)" % overlap, "overlap fraction %.3f < 0.5: the two programs did not run together" % overlap)
        if 0.5 <= overlap < 0.9:
            warn("overlap fraction %.3f < 0.9: the tail of the window is one program alone" % overlap)
    elif len(reports) == 2:
        fails.append("a report is missing one of: matrix size, processors, block size, start, finish, total time")

# ───────────────────────── counters ─────────────────────────
KEYS = ["accessA", "primaryHit", "secondaryHit", "dataMiss", "upgradeMiss", "memReads", "memWrites",
        "memAcqPerm", "memRelClean", "migrations", "secHits", "parked", "attempted", "L2_Cycles"]
miss = [k for k in KEYS if k not in win]
need(not miss, "all needed counters present in the window line", "window line lacks %s" % miss)
if not miss:
    for k in ["accessA", "memReads", "memWrites", "migrations", "L2_Cycles"]:
        need(civ(k) == win[k], "CSV %s == transcript" % k, "CSV %s=%s but transcript %s" % (k, r.get(k), win[k]))
    gap = win["accessA"] - (win["primaryHit"] + win["secondaryHit"] + win["dataMiss"] + win["upgradeMiss"])
    need(abs(gap) <= 64, "four-outcome identity gap %+d (|gap|<=64)" % gap, "four-outcome identity gap %+d exceeds 64" % gap)
    fills = win["memReads"] + win["memAcqPerm"]
    need(fills == win["dataMiss"] + win["upgradeMiss"], "memReads+memAcqPerm == dataMiss+upgradeMiss",
         "memReads+memAcqPerm=%d != dataMiss+upgradeMiss=%d" % (fills, win["dataMiss"] + win["upgradeMiss"]))
    need(win["accessA"] > 0 and win["L2_Cycles"] > 0, "accessA and L2_Cycles > 0", "accessA or L2_Cycles is 0")
    ev = fills - (win["memWrites"] + win["memRelClean"])  # fills not matched by an announced eviction
    if a.phase == "off":
        need(win["migrations"] == 0 and win["secHits"] == 0 and win["secondaryHit"] == 0 and win["parked"] == 0 and win["attempted"] == 0,
             "OFF: no SBC activity (migrations/secHits/secondaryHit/parked/attempted all 0)",
             "OFF but SBC was active: migrations=%d secHits=%d secondaryHit=%d parked=%d attempted=%d" % (
                 win["migrations"], win["secHits"], win["secondaryHit"], win["parked"], win["attempted"]))
        need(abs(ev) <= 64, "OFF: fills - announced evictions = %+d (|.|<=64)" % ev, "OFF: fills - announced evictions = %+d, exceeds 64" % ev)
    else:
        need(-64 <= ev <= win["migrations"] + 64, "ON: evictionless fills %d within migrations %d" % (ev, win["migrations"]),
             "ON: evictionless fills %d outside [-64, migrations+64=%d]" % (ev, win["migrations"] + 64))
        if win["migrations"] == 0:
            warn("ON window with migrations=0: the switch read back ON but SBC never migrated at this point (a valid 'no effect' result)")

print("---- stage check: %s  %s  %s" % (a.phase.upper(), a.label, os.path.basename(a.csv)))
for m in oks:
    print("  ok    " + m)
for m in warns:
    print("  WARN  " + m)
for m in fails:
    print("  FAIL  " + m)
if win and not fails:
    acc = win["accessA"]
    print("  RESULT %s %s memReads=%d memWrites=%d memAcc=%d accessA=%d hit=%.2f%% migrations=%d secondaryHit=%d L2_Cycles=%d" % (
        a.phase, a.label, win["memReads"], win["memWrites"], win["memReads"] + win["memWrites"], acc,
        100.0 * (win["primaryHit"] + win["secondaryHit"]) / acc, win["migrations"], win["secondaryHit"], win["L2_Cycles"]))
    if len(reports) == 2 and overlap is not None:
        print("  PROGRAMS b%s: %.2f s, b%s: %.2f s (each program's own 'total time without initialization'), overlap %.3f" % (
            exp_ba, reports[0]["total_us"] / 1e6, exp_bb, reports[1]["total_us"] / 1e6, overlap))
verdict = "VALID" if not fails else "VOID"
print("stage verdict: %s" % verdict)
if a.json:
    json.dump({"label": a.label, "phase": a.phase, "verdict": verdict, "counters": win, "csv": a.csv, "log": a.log,
               "p": exp_p, "n": exp_n, "b": [exp_ba, exp_bb], "policy": exp_pol, "bit_sha256": sha,
               "reports": reports, "overlap_frac": overlap, "warnings": warns, "failures": fails},
              open(a.json, "w"), indent=1)
sys.exit(0 if not fails else 1)
