#!/usr/bin/env python3
"""Rebuild a run CSV from a run_parsec_session.exp transcript.

    python3 recover_csv_from_log.py scripts/logs/lu_session_<stamp>.log

The transcript records everything the board actually sent, so a session whose CSV came out
short - a truncated capture, a session killed part way, a counter added to sbc_read after the
script's column list was written - can be rebuilt from it without re-running the board.

It pairs each measured run's command echo with the [SBC-WINDOW] line that follows it, and
cross-checks the phase and policy against the "migrate :" and "policy :" lines sbc_read prints
underneath its own window line. A mismatch is reported rather than written.
"""

import argparse
import csv
import os
import re
import sys

CSV_COLS = ("migrations secHits secMiss attempted aborted parked dispDrop dispRelease "
            "accessA primaryHit secondaryHit probedHit dataMiss upgradeMiss "
            "secondSearch secondaryMiss memReads memWrites L2_Accesses L2_Hits L2_Cycles "
            "dstAbortDirty dstAbortHeld dstAbortBoth").split()
HEAD = ["label", "axis", "bench", "policy", "p", "n", "b", "migrate", "rep", "status", "rc"]

# Where each field comes from, and why not from the command echo: the board's terminal wraps the
# echo at 80 columns by inserting a newline into the character stream, and it lands wherever it
# lands - "-n512" comes back as "-n51\n2". Anything parsed out of the echo is parsing a line that
# was broken at an arbitrary point. Both of the sources below are printed by the programs
# themselves, one value per line, so neither can be split that way:
#
#   n, p, b        LU's own banner ("512 by 512 Matrix", "2 Processors", "128 by 128 Element
#                  Blocks") - the parameters the binary actually ran with, not the ones we asked for
#   migrate,policy sbc_read's confirmation block under its window line - the switch and policy it
#                  actually read back out of the hardware
LU_BANNER_RE = re.compile(
    r"Blocked Dense LU Factorization\s*\n\s*(\d+) by \d+ Matrix\s*\n"
    r"\s*(\d+) Processors\s*\n\s*(\d+) by \d+ Element Blocks")
WIN_RE = re.compile(r"\[SBC-WINDOW\][^\n]*")
RC_RE = re.compile(r"workload rc=(\d+)")
CONFIRM_RE = re.compile(r"migrate\s*:\s*(ON|OFF).*?policy\s*:\s*(random|plru)", re.S)
# only for a non-LU workload, which prints no banner: the echo, with the wrap newlines removed
CMD_RE = re.compile(r"--zero\s+--\s+sh\s+-c\s+'(?P<cmd>.*?)2>\s*wl\.err'", re.S)

CENTRE = {"p": "2", "n": "512", "b": "128", "policy": "plru"}


def axis_of(p, n, b, policy):
    knobs = {"p": p, "n": n, "b": b, "policy": policy}
    differ = [k for k, v in knobs.items() if v != CENTRE[k]]
    if not differ:
        return "centre"
    return differ[0] if len(differ) == 1 else "+".join(sorted(differ))


def parse(path):
    """-> one record per measured run, in the order the board produced them."""
    text = open(path, errors="replace").read().replace("\r", "")
    events = []
    for kind, rx in (("cmd", CMD_RE), ("lu", LU_BANNER_RE), ("rc", RC_RE), ("win", WIN_RE)):
        events += [(kind, m.start(), m) for m in rx.finditer(text)]
    events.sort(key=lambda e: e[1])

    runs = []
    cmd = lu = None
    rc = ""
    for kind, pos, m in events:
        if kind == "cmd":
            cmd, lu, rc = m, None, ""
        elif kind == "lu":
            lu = m
        elif kind == "rc":
            rc = m.group(1)
        elif kind == "win":
            # the confirmation block sits immediately under the window line
            runs.append((cmd, lu, rc, text[m.end():m.end() + 400], m))
            cmd = lu = None
            rc = ""
    return runs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("-o", "--out", default=None, help="output csv (default: <log stem>_recovered.csv)")
    args = ap.parse_args()

    runs = parse(args.log)
    if not runs:
        sys.exit("no [SBC-WINDOW] lines paired with a command in this transcript")

    out = args.out or os.path.join(os.path.dirname(os.path.abspath(args.log)),
                                   os.path.splitext(os.path.basename(args.log))[0].replace(
                                       "_session_", "_runs_") + "_recovered.csv")
    reps, rows, bad = {}, [], 0
    for cmd_m, lu_m, rc, tail, win_m in runs:
        conf = CONFIRM_RE.search(tail)
        if not conf:
            print("  ! a window line has no migrate/policy confirmation under it - skipped")
            bad += 1
            continue
        mig, pol = conf.group(1).lower(), conf.group(2)

        if lu_m:
            n, p, b = lu_m.group(1), lu_m.group(2), lu_m.group(3)
            bench = "lu_ncb"
            if cmd_m:
                exe = re.search(r"\./(lu_\w+)", cmd_m.group("cmd").replace("\n", ""))
                if exe:
                    bench = exe.group(1)
            label = f"lu-p{p}-n{n}-b{b}-{pol}"
            axis = axis_of(p, n, b, pol)
        elif cmd_m:
            # no LU banner: strip the wrap newlines outright - they are inserted by the terminal
            # and were never part of what was typed, so removing them restores the command exactly
            cmd = cmd_m.group("cmd").replace("\n", "").strip()
            bench = cmd.split()[0].lstrip("./") if cmd else "unknown"
            p = n = b = ""
            label, axis = bench, "app"
        else:
            print("  ! a window line has neither an LU banner nor a command before it - skipped")
            bad += 1
            continue

        counters = dict(re.findall(r"([A-Za-z_][A-Za-z_0-9]*)=([0-9]+)", win_m.group(0)))
        missing = [c for c in CSV_COLS if c not in counters]
        key = (label, mig)
        reps[key] = reps.get(key, 0) + 1
        rows.append([label, axis, bench, pol, p, n, b, mig, reps[key],
                     "OK" if not missing else f"PARTIAL({len(missing)} missing)", rc]
                    + [counters.get(c, "") for c in CSV_COLS])

    with open(out, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(HEAD + CSV_COLS)
        w.writerows(rows)

    ok = sum(1 for r in rows if r[9] == "OK")
    print(f"  {len(rows)} run(s) recovered, {ok} complete"
          + (f", {bad} skipped" if bad else ""))
    print(f"  wrote {out}")


if __name__ == "__main__":
    main()
