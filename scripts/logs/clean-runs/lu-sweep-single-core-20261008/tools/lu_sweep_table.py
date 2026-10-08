#!/usr/bin/env python3
"""Build results/results.csv and results/table.md from the VALID stages of the LU sweep.

usage: lu_sweep_table.py <sweep_dir>

Reads <sweep_dir>/{off,on}/<label>/stage_result.json (written by check_lu_stage.py; only verdict VALID
counts). One run per arm per point, every window on its own fresh boot. There is no spread to report: a
difference smaller than the run-to-run noise seen elsewhere on this board (about 0.3-1.5%) is not an effect.

memReads and memWrites are always shown separately as well as summed (SBC can trade one for the other).
Hit rate = (primaryHit + secondaryHit) / accessA; probedHit is never added. The same-work check
(accessA ON vs OFF within 1%) is FLAGGED here, never used to drop or retry a run.

v2 (2026-10-08): works on a PARTIAL sweep. A point with only one arm shows that arm's numbers and '-' for the
rest (no delta is computed from half a pair); a banner at the top says how many stages are valid so far and when
the table was written. Dropped stages (dropped/<phase>-<label>.txt) are listed and marked.

v3 (2026-10-08): the main table shows the L2 cycle counts themselves (off, on) next to their change, not only the
change; results.csv gains L2cyc_delta. L2 cycles = L2_Cycles of the [SBC-WINDOW] line = the free-running L2 clock
(50 MHz) over exactly the measured window, i.e. the window's wall time. With the same work (accessA within 1%),
fewer cycles with SBC on is a faster run. The previous version is kept as lu_sweep_table.py.v2.
"""
import csv, glob, json, os, re, sys, time

sw = sys.argv[1]
os.makedirs(f"{sw}/results", exist_ok=True)
BLOCK = 64.0                  # bytes per L2 line
POINTS = 9                    # points in the sweep, one stage per arm each


def load(phase):
    d = {}
    for p in sorted(glob.glob(f"{sw}/{phase}/*/stage_result.json")):
        j = json.load(open(p))
        if j.get("verdict") == "VALID":
            d[j["label"]] = j
    return d


off, on = load("off"), load("on")

# stages the launcher dropped after every attempt stalled before any window (dropped/<phase>-<label>.txt)
dropped = set()
for _p in sorted(glob.glob(f"{sw}/dropped/*.txt")):
    _m = re.fullmatch(r"(off|on)-(lu-p\d+-n\d+-b\d+-\w+)\.txt", os.path.basename(_p))
    if _m:
        dropped.add((_m.group(1), _m.group(2)))


# failed attempts kept per stage: failed/<phase>-<label>-attempt<N>-<time>[...]
failed_n = {}
if os.path.isdir(f"{sw}/failed"):
    for _d in os.listdir(f"{sw}/failed"):
        _m = re.match(r"(off|on)-(lu-p\d+-n\d+-b\d+-[a-z]+)-attempt\d+-", _d)
        if _m:
            failed_n[(_m.group(1), _m.group(2))] = failed_n.get((_m.group(1), _m.group(2)), 0) + 1


def key(label):
    m = re.fullmatch(r"lu-p(\d+)-n(\d+)-b(\d+)-(\w+)", label)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)))


labels = sorted(set(off) | set(on) | {l for _, l in dropped} | {l for _, l in failed_n}, key=lambda l: (key(l)[1], key(l)[2]))


def pct(new, old):
    return 100.0 * (new - old) / old if old else float("nan")


def hit(c):
    return 100.0 * (c["primaryHit"] + c["secondaryHit"]) / c["accessA"]


def arm_vals(c, sfx):
    return {"accessA_" + sfx: c["accessA"], "memReads_" + sfx: c["memReads"], "memWrites_" + sfx: c["memWrites"],
            "memAcc_" + sfx: c["memReads"] + c["memWrites"], "hit_" + sfx: hit(c),
            "L2cyc_" + sfx: c["L2_Cycles"], "secs_" + sfx: c["L2_Cycles"] / 50e6}


rows = []
for lab in labels:
    p, n, b = key(lab)
    r = {"label": lab, "n": n, "b": b, "p": p, "policy": lab.split("-")[-1],
         "have_off": lab in off, "have_on": lab in on}
    if lab in off:
        r.update(arm_vals(off[lab]["counters"], "off"))
    if lab in on:
        o = on[lab]["counters"]
        r.update(arm_vals(o, "on"))
        r.update({"sec_pct_on": 100.0 * o["secondaryHit"] / o["accessA"],
                  "migrations_on": o["migrations"], "secondaryHit_on": o["secondaryHit"]})
    flags = []
    if lab in off and lab in on:
        a = off[lab]["counters"]
        r.update({
            "accessA_dpct": pct(o["accessA"], a["accessA"]),
            "memReads_dpct": pct(o["memReads"], a["memReads"]),
            "memWrites_dpct": pct(o["memWrites"], a["memWrites"]),
            "memAcc_delta": r["memAcc_on"] - r["memAcc_off"], "MB": (r["memAcc_on"] - r["memAcc_off"]) * BLOCK / 2**20,
            "memAcc_dpct": pct(r["memAcc_on"], r["memAcc_off"]),
            "hit_dpp": r["hit_on"] - r["hit_off"],
            "L2cyc_delta": o["L2_Cycles"] - a["L2_Cycles"],
            "L2cyc_dpct": pct(o["L2_Cycles"], a["L2_Cycles"]),
        })
        if abs(r["accessA_dpct"]) > 1.0:
            flags.append("WORK DIFFERS %.1f%%" % r["accessA_dpct"])
        if o["migrations"] == 0:
            flags.append("ON migrations=0")
    else:
        for s, have in (("OFF", lab in off), ("ON", lab in on)):
            if have:
                continue
            nf = failed_n.get((s.lower(), lab), 0)
            if (s.lower(), lab) in dropped:
                flags.append("%s GAVE UP (void on every attempt, %d failed)" % (s, nf))
            elif nf:
                flags.append("%s failed %d time(s), retry pending" % (s, nf))
            else:
                flags.append("%s not run yet" % s)
    for s, d in (("OFF", off), ("ON", on)):                # arms that only became valid in the retry pass
        if lab in d and os.path.exists(f"{sw}/{s.lower()}/{lab}/retry_pass.txt"):
            flags.append("%s validated in the retry pass (ran after the other stages of the sweep)" % s)
    r["flags"] = "; ".join(flags)
    rows.append(r)

cols = ["label", "n", "b", "p", "policy", "have_off", "have_on",
        "accessA_off", "accessA_on", "accessA_dpct",
        "memReads_off", "memReads_on", "memReads_dpct", "memWrites_off", "memWrites_on", "memWrites_dpct",
        "memAcc_off", "memAcc_on", "memAcc_delta", "MB", "memAcc_dpct",
        "hit_off", "hit_on", "hit_dpp", "sec_pct_on", "migrations_on", "secondaryHit_on",
        "L2cyc_off", "L2cyc_on", "L2cyc_delta", "L2cyc_dpct", "secs_off", "secs_on", "flags"]
with open(f"{sw}/results/results.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
    w.writeheader()
    for r in rows:
        w.writerow(r)


def f0(x): return "%s" % format(int(x), ",") if isinstance(x, (int, float)) and x == x else "-"
def fs(x, d=2): return ("%+.*f" % (d, x)) if isinstance(x, (int, float)) and x == x else "-"
def fp(x, d=2): return ("%.*f" % (d, x)) if isinstance(x, (int, float)) and x == x else "-"
def pc(x, d=2): return ("%+.*f%%" % (d, x)) if isinstance(x, (int, float)) and x == x else "-"
def fd(x): return format(int(x), "+,") if isinstance(x, (int, float)) and x == x else "-"
def ft(x): return ("%.1f" % x) if isinstance(x, (int, float)) and x == x else "-"


out = []
out.append("# LU sweep, single core: SBC off vs on, every window on its own fresh boot\n")
nvalid = len(off) + len(on)
if len(off) < POINTS or len(on) < POINTS or dropped:
    out.append("> **PARTIAL TABLE**, written %s: %d of %d stages are valid so far (%d of %d OFF, %d of %d ON)%s. "
               "All OFF stages run before any ON stage, so no OFF-vs-ON difference exists until ON stages finish; "
               "a point with one arm shows that arm's numbers only. The chain rewrites this file when it finishes.\n" % (
                   time.strftime("%Y-%m-%d %H:%M:%S"), nvalid, 2 * POINTS, len(off), POINTS, len(on), POINTS,
                   "; %d stage(s) given up" % len(dropped) if dropped else ""))
out.append("One run per arm per point (n=1 each): **no spread is available**, so a difference under roughly 0.3-1.5% "
           "(the run-to-run noise seen elsewhere on this board) is not an effect. Single core, `lu_ncb -p1`, PLRU, "
           "256 KB 8-way L2, bitstream sha256 `5ace41250e7c5141…`. memAcc = memReads + memWrites. "
           "MB = memAcc delta × 64 B. Hit rate = (primary + secondary) / accessA. sec% = secondary hits / accesses (ON). "
           "L2 cycles = the L2 clock (50 MHz) counted over exactly the measured window, so it is the window's run time "
           "(seconds = cycles / 50e6); with the same work in both arms (accessA within 1%), fewer cycles with SBC on "
           "means a faster run. The one fresh-boot repeat that exists (a void attempt, see Provenance) is the only noise "
           "reference for the cycle and traffic columns, and one repeat is not a spread.\n")
out.append("## Main table (negative = SBC reduced memory traffic / run time)\n")
out.append("| n | b | p | pol | memAcc off | memAcc on | memAcc Δ | MB | Δ% | hit% off | hit% on | Δpp | sec% | L2 cycles off | L2 cycles on | L2 cycles Δ | L2 cycles Δ% | status |")
out.append("|--:|--:|--:|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|")
for r in rows:
    g = r.get
    out.append("| %d | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
        r["n"], r["b"], r["p"], r["policy"], f0(g("memAcc_off")), f0(g("memAcc_on")), fd(g("memAcc_delta")),
        fs(g("MB"), 1), pc(g("memAcc_dpct")), fp(g("hit_off")), fp(g("hit_on")), fs(g("hit_dpp")),
        fp(g("sec_pct_on")), f0(g("L2cyc_off")), f0(g("L2cyc_on")), fd(g("L2cyc_delta")), pc(g("L2cyc_dpct")),
        r["flags"] or ""))
out.append("\n## Reads and writes separately (SBC can trade one for the other)\n")
out.append("| n | b | memReads off | memReads on | Δ% | memWrites off | memWrites on | Δ% | accessA off | accessA on | Δ% | migrations (on) | secondary hits (on) | window off→on (s) |")
out.append("|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
for r in rows:
    g = r.get
    out.append("| %d | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s → %s |" % (
        r["n"], r["b"], f0(g("memReads_off")), f0(g("memReads_on")), pc(g("memReads_dpct")),
        f0(g("memWrites_off")), f0(g("memWrites_on")), pc(g("memWrites_dpct")),
        f0(g("accessA_off")), f0(g("accessA_on")), pc(g("accessA_dpct")),
        f0(g("migrations_on")), f0(g("secondaryHit_on")), ft(g("secs_off")), ft(g("secs_on"))))
failed = sorted(os.listdir(f"{sw}/failed")) if os.path.isdir(f"{sw}/failed") else []
out.append("\n## Provenance\n")
out.append("- valid stages: %d OFF, %d ON (of %d each)" % (len(off), len(on), POINTS))
out.append("- void attempts kept under `failed/`: %d" % len(failed))
for f in failed:
    why = []
    try:
        why = [l.strip()[5:].strip() for l in open(f"{sw}/failed/{f}/stage_check.txt") if l.startswith("  FAIL")]
    except OSError:
        pass
    note = ""
    if os.path.exists(f"{sw}/failed/{f}/NOTE.txt"):
        note += " [see NOTE.txt]"
    rc2 = f"{sw}/failed/{f}/recheck_with_checker_v2.txt"
    if os.path.exists(rc2):
        v2 = [l.strip() for l in open(rc2) if l.startswith("stage verdict:")]
        note += " [re-check with checker v2, for information only: %s]" % (v2[-1][14:].strip() if v2 else "?")
    out.append("  - `%s`: %s%s" % (f, "; ".join(why[:3]) + (" ..." if len(why) > 3 else "") if why else "no stage_check.txt", note))
# A void attempt that still measured a window is a second fresh-boot run of the same arm: it shows how far two such
# runs differ in cycles and traffic. Reference only; it never enters the table above.
for f in failed:
    m = re.match(r"(off|on)-(lu-p\d+-n\d+-b\d+-[a-z]+)-(attempt\d+-\d+)", f)
    valid = (off if m and m.group(1) == "off" else on) if m else {}
    if not m or m.group(2) not in valid:
        continue
    try:
        rr = list(csv.DictReader(open(glob.glob(f"{sw}/failed/{f}/lu_runs_*.csv")[0])))
        if len(rr) != 1 or rr[0]["status"] != "OK" or int(rr[0]["L2_Cycles"]) <= 0:
            continue
        v = valid[m.group(2)]["counters"]
        x = {k: int(rr[0][k]) for k in ("L2_Cycles", "memReads", "memWrites", "accessA")}
    except (IndexError, KeyError, ValueError, OSError):
        continue
    out.append("- fresh-boot repeat, reference only (a void attempt that still measured a window): %s `%s` (`%s`) vs its valid stage: "
               "L2 cycles %s, memAcc %s, accessA %s" % (
                   m.group(1).upper(), m.group(2), m.group(3),
                   pc(pct(x["L2_Cycles"], v["L2_Cycles"])),
                   pc(pct(x["memReads"] + x["memWrites"], v["memReads"] + v["memWrites"])),
                   pc(pct(x["accessA"], v["accessA"]))))
if dropped:
    out.append("- **stages given up** (void on every attempt, including the retries after the sweep): " +
               ", ".join("%s `%s`" % (ph.upper(), lab) for ph, lab in sorted(dropped)) + " — reasons in `dropped/`")
retried = [(ph, lab) for ph, d in (("off", off), ("on", on)) for lab in sorted(d) if os.path.exists(f"{sw}/{ph}/{lab}/retry_pass.txt")]
if retried:
    out.append("- stages that became valid only in the retry pass (they ran after the other stages; an OFF stage here ran after the ON half): " +
               ", ".join("%s `%s`" % (ph.upper(), lab) for ph, lab in retried))
warned = [(ph, lab, w) for ph, d in (("off", off), ("on", on)) for lab, j in sorted(d.items()) for w in j.get("warnings", [])]
if warned:
    out.append("- valid stages that carry warnings:")
    for ph, lab, w in warned:
        out.append("  - %s `%s`: %s" % (ph.upper(), lab, w))
out.append("- plan, method and validity gate: `PLAN.md`; every stage's checks: `chain_status.txt` and `<phase>/<label>/stage_check.txt`")
open(f"{sw}/results/table.md", "w").write("\n".join(out) + "\n")
print("\n".join(out))
