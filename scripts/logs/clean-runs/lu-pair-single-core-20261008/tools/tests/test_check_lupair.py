#!/usr/bin/env python3
"""Host-only tests for tools/check_lupair_stage.py. No board.

usage: test_check_lupair.py <scratch_dir>

The fixtures are REAL sweep transcripts and CSVs (an OFF stage and an ON stage of lu-sweep-single-core-20261008) rewritten
into what a pair stage would print: the measured command echo is replaced by the two-lu_ncb command wrapped at 80 columns
the way the board's tty wraps it ("\\r\\r\\n"), the solo LU report in front of the window is replaced by the PAIR-RC line,
and the two reports are appended after "workload rc=" behind the post-window "cat" command. Counters are the real
window's, so every counter rule is exercised on real numbers. Then single faults are injected and the verdict is checked.
"""
import csv, os, re, subprocess, sys

SW = "/home/damith/Research/repos/chipyard_performance_eval/chipyard/scripts/logs/clean-runs/lu-sweep-single-core-20261008"
TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECK = os.path.join(TOOLS, "check_lupair_stage.py")
BIT = "/home/damith/Research/repos/chipyard_performance_eval/chipyard/fpga/bitstream_storage/FPGASingleRocketVCU118L18K256K8WL2ConfigSBCPLRU-256KB-8way-candidate013-2026-10-01-2026-10-01.bit"
BIT_SHA = "5ace41250e7c5141"
scratch = sys.argv[1]
os.makedirs(scratch, exist_ok=True)

SRC = {"off": ("off/lu-p1-n512-b32-plru", "20261008-044812"), "on": ("on/lu-p1-n512-b128-plru", None)}
for ph, (d, stamp) in list(SRC.items()):
    files = sorted(os.listdir(os.path.join(SW, d)))
    log = [f for f in files if f.startswith("lu_session_")][0]
    SRC[ph] = (os.path.join(SW, d, log), os.path.join(SW, d, log.replace("lu_session_", "lu_runs_").replace(".log", ".csv")))


def wrap80(s):
    out, first = [], True
    while len(s) > 80:
        out.append(s[:80]); s = s[80:]
    out.append(s)
    return "\r\r\n".join(out)


def inner(n, ba, bb):
    return ("./lu_ncb -p1 -n%s -b%s >a.out 2>a.err & PA=$! ; ./lu_ncb -p1 -n%s -b%s >b.out 2>b.err & PB=$! ; "
            "wait $PA ; RA=$? ; wait $PB ; RB=$? ; echo PAIR-RC a=$RA b=$RB ; test $RA -eq 0 && test $RB -eq 0 2> wl.err" % (n, ba, n, bb))


def report(n, b, start, finish, procs=1):
    tot = finish - start
    return ("\r\nBlocked Dense LU Factorization\r\n     %d by %d Matrix\r\n     %d Processors\r\n     %d by %d Element Blocks\r\n\r\n\r\n"
            "                            PROCESS STATISTICS\r\n              Total      Diagonal     Perimeter      Interior       Barrier\r\n"
            " Proc         Time         Time         Time           Time          Time\r\n    0      %d        101220       2152360      19233560          1100\r\n\r\n"
            "                            TIMING INFORMATION\r\nStart time                        :        %d\r\n"
            "Initialization finish time        :        %d\r\nOverall finish time               :        %d\r\n"
            "Total time with initialization    :         %d\r\nTotal time without initialization :         %d\r\n"
            % (n, n, procs, b, b, tot, start, start + 8500, finish, tot + 8500, tot))


def make(name, phase, n=512, ba=32, bb=128, label=None, cmd_n=None, cmd_ba=None, cmd_bb=None, rc_line="PAIR-RC a=0 b=0",
         reports=None, drop_post_cmd=False, extra_before_window="", extra_in_report="", csv_edit=None, log_edit=None):
    logp, csvp = SRC[phase]
    txt = open(logp, "rb").read().decode("latin-1")
    cmd = inner(cmd_n or n, cmd_ba or ba, cmd_bb or bb)
    echo = "# /root/sbc_read --migrate=%s --policy=plru --zero -- sh -c '%s' ; echo \"workload rc=$?\" ; tail -5 wl.err\r\n" % (phase, cmd)
    pat = re.compile(r"# /root/sbc_read --migrate=(on|off) --policy=(\w+) --zero -- sh -c '.*?tail -5 wl\.err\r\n.*?(?=\[SBC-WINDOW\])", re.S)
    assert pat.search(txt), "fixture source has no measured-command block"
    # the tty wraps the echoed line at 80 columns; the trailing "\r\n" is not part of the line being wrapped
    txt = pat.sub(lambda m: wrap80(echo[:-2]) + "\r\n" + extra_before_window + (rc_line + "\r\n" if rc_line else ""), txt, count=1)
    if reports is None:
        reports = [report(n, ba, 343_401_960, 343_401_960 + 45_200_000), report(n, bb, 343_421_960, 343_421_960 + 46_700_000)]
    post = "" if drop_post_cmd else "# cat a.out b.out a.err b.err\r\n" + "".join(reports) + extra_in_report
    txt = txt.replace("workload rc=0\r\n", "workload rc=0\r\n" + post, 1)
    if log_edit:
        txt = log_edit(txt)
    lp = os.path.join(scratch, "lupair_session_%s.log" % name)
    open(lp, "wb").write(txt.encode("latin-1"))
    rows = list(csv.DictReader(open(csvp)))
    assert len(rows) == 1
    r = rows[0]
    r.update({"label": label or "lupair-p1-n%s-b%s+b%s-plru" % (n, ba, bb), "axis": "lupair", "bench": "lu_ncb", "p": "1", "n": str(n), "b": "%s+%s" % (ba, bb)})
    if csv_edit:
        csv_edit(r)
    cp = os.path.join(scratch, "lupair_runs_%s.csv" % name)
    w = csv.DictWriter(open(cp, "w", newline=""), fieldnames=list(r.keys()))
    w.writeheader(); w.writerow(r)
    return cp, lp


def run(name, phase, expect_exit, must_have=(), must_not=(), label=None, **kw):
    cp, lp = make(name, phase, label=label, **kw)
    lab = label or "lupair-p1-n%s-b%s+b%s-plru" % (kw.get("n", 512), kw.get("ba", 32), kw.get("bb", 128))
    p = subprocess.run([sys.executable, CHECK, "--csv", cp, "--log", lp, "--phase", phase, "--label", "lupair-p1-n512-b32+b128-plru",
                        "--bit", BIT, "--bit-sha", BIT_SHA, "--json", os.path.join(scratch, name + ".json")], capture_output=True, text=True)
    out = p.stdout + p.stderr
    good = p.returncode == expect_exit and all(s in out for s in must_have) and not any(s in out for s in must_not)
    print("%-4s %-34s exit=%d (want %d)%s" % ("PASS" if good else "FAIL", name, p.returncode, expect_exit,
                                              "" if good else "\n" + "\n".join("      " + l for l in out.splitlines() if "FAIL" in l or "verdict" in l or "Traceback" in l or "Error" in l)))
    return good


results = []
R = results.append
# positive
R(run("off_good", "off", 0, ["stage verdict: VALID", "PAIR-RC a=0 b=0 seen once", "exactly 2 LU reports", "overlap fraction 0.9"]))
R(run("on_good", "on", 0, ["stage verdict: VALID", "ON: evictionless fills"]))
# the same, with a 0.8 overlap: valid with a warning
R(run("overlap_warn", "off", 0, ["stage verdict: VALID", "WARN  overlap fraction"],
      reports=[report(512, 32, 343_401_960, 343_401_960 + 40_000_000), report(512, 128, 343_401_960 + 8_000_000, 343_401_960 + 48_000_000)]))
# negative: each one fault
R(run("rc_b_killed", "off", 1, ["FAIL  PAIR-RC lines: [('0', '137')]"], rc_line="PAIR-RC a=0 b=137"))
R(run("rc_missing", "off", 1, ["FAIL  PAIR-RC lines: []"], rc_line=""))
R(run("rc_dollar_only", "off", 1, ["FAIL  PAIR-RC lines: []"], rc_line="PAIR-RC a=$RA b=$RB"))
R(run("no_post_cmd", "off", 1, ["FAIL  the post-window 'cat a.out b.out ...' command was not found"], drop_post_cmd=True))
R(run("one_report", "off", 1, ["FAIL  1 LU reports after the window"], reports=[report(512, 32, 343_401_960, 343_401_960 + 45_200_000)]))
R(run("zero_reports", "off", 1, ["FAIL  0 LU reports after the window"], reports=[]))
R(run("reports_swapped", "off", 1, ["FAIL  report blocks are 128 then 32"],
      reports=[report(512, 128, 343_421_960, 343_421_960 + 46_700_000), report(512, 32, 343_401_960, 343_401_960 + 45_200_000)]))
R(run("wrong_matrix", "off", 1, ["FAIL  matrix sizes 256 / 512"],
      reports=[report(256, 32, 343_401_960, 343_401_960 + 45_200_000), report(512, 128, 343_421_960, 343_421_960 + 46_700_000)]))
R(run("two_procs", "off", 1, ["FAIL  processor counts 2 / 1"],
      reports=[report(512, 32, 343_401_960, 343_401_960 + 45_200_000, procs=2), report(512, 128, 343_421_960, 343_421_960 + 46_700_000)]))
R(run("no_overlap", "off", 1, ["FAIL  overlap fraction 0.0", "did not run together"],
      reports=[report(512, 32, 343_401_960, 343_401_960 + 20_000_000), report(512, 128, 343_401_960 + 25_000_000, 343_401_960 + 50_000_000)]))
# a partial overlap just under the void line (0.45) is void; just over (0.55) is valid with a warning
R(run("overlap_045", "off", 1, ["FAIL  overlap fraction 0.450"],
      reports=[report(512, 32, 0, 60_000_000), report(512, 128, 15_000_000, 100_000_000)]))     # shared 45 of 100 s
R(run("overlap_055", "off", 0, ["stage verdict: VALID", "WARN  overlap fraction 0.550"],
      reports=[report(512, 32, 0, 70_000_000), report(512, 128, 15_000_000, 100_000_000)]))     # shared 55 of 100 s
R(run("cmd_wrong_b", "off", 1, ["FAIL  measured command(s) in the transcript"], cmd_bb=64))
R(run("cmd_wrong_n", "off", 1, ["FAIL  measured command(s) in the transcript"], cmd_n=256))
R(run("csv_rc1", "off", 1, ["FAIL  rc=1"], csv_edit=lambda r: r.update({"rc": "1"})))
R(run("csv_status_timeout", "off", 1, ["FAIL  status=TIMEOUT"], csv_edit=lambda r: r.update({"status": "TIMEOUT"})))
R(run("csv_b_wrong", "off", 1, ["FAIL  p/n/b ="], csv_edit=lambda r: r.update({"b": "32+64"})))
R(run("csv_phase_wrong", "on", 1, ["FAIL  CSV migrate=off"], csv_edit=lambda r: r.update({"migrate": "off"})))
R(run("kernel_panic", "off", 1, ["FAIL  kernel panic / oops / BUG"], log_edit=lambda t: t.replace("workload rc=0", "Kernel panic - not syncing: x\r\nworkload rc=0", 1)))
R(run("lockup_in_window", "off", 1, ["FAIL  workqueue lockup printed WHILE the window was open"],
      extra_before_window="BUG: workqueue lockup - pool cpus=0 node=0 flags=0x0 nice=0 stuck for 31s!\r\n"))
R(run("lockup_in_staging_only", "off", 0, ["stage verdict: VALID", "WARN  1 'BUG: workqueue lockup' line(s) before"],
      log_edit=lambda t: t.replace("# test -x ./lu_ncb", "BUG: workqueue lockup - pool stuck for 31s!\r\n# test -x ./lu_ncb", 1)))
R(run("two_boots", "off", 1, ["FAIL  2 Linux boots"], log_edit=lambda t: t + "\r\n[    0.000000] Linux version 6.6.0\r\n"))
R(run("harness_bang", "off", 1, ["FAIL  harness errors"], log_edit=lambda t: t + "\n!!! something went wrong\n"))
R(run("rc_nonzero_workload", "off", 1, ["FAIL  workload rc lines"], log_edit=lambda t: t.replace("workload rc=0", "workload rc=1", 1)))
print("\n%d of %d checks behaved as expected" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
