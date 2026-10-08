#!/usr/bin/env python3
"""Fixture maker for the launch_pairs.sh test: real sweep windows rewritten into pair stages for several (bA,bB).

usage: make_fixtures.py <scratch_dir>

The fixtures are REAL sweep transcripts and CSVs (an OFF stage and an ON stage of lu-sweep-single-core-20261008) rewritten
into what a pair stage would print: the measured command echo is replaced by the two-lu_ncb command wrapped at 80 columns
the way the board's tty wraps it ("\\r\\r\\n"), the solo LU report in front of the window is replaced by the PAIR-RC line,
and the two reports are appended after "workload rc=" behind the post-window "cat" command. Counters are the real
window's, so every counter rule is exercised on real numbers. Then single faults are injected and the verdict is checked.
"""
import csv, os, re, subprocess, sys

SW = "/home/damith/Research/repos/chipyard_performance_eval/chipyard/scripts/logs/clean-runs/lu-sweep-single-core-20261008"
TOOLS = "/home/damith/Research/repos/chipyard_performance_eval/chipyard/scripts/logs/clean-runs/lu-pair-single-core-20261008/tools"
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



if __name__ == "__main__":
    n = 0
    for ph in ("off", "on"):
        for (ba, bb) in ((64, 64), (32, 32), (64, 256), (64, 128), (128, 128)):
            make("%s_%d_%d" % (ph, ba, bb), ph, ba=ba, bb=bb); n += 1
    # a void window: program b killed (PAIR-RC b=137)
    make("rc_b_killed_64_64", "off", ba=64, bb=64, rc_line="PAIR-RC a=0 b=137")
    print("wrote %d fixtures (+1 void) into %s" % (n, scratch))
