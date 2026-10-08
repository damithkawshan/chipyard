#!/usr/bin/env python3
"""Build results/table.md and results/results.csv for the single-core LU-pair test.

usage: lu_pair_table.py <pair_dir> [<sweep_dir>]

Reads the VALID pair stages <pair_dir>/{off,on}/<label>/stage_result.json (written by check_lupair_stage.py) and the
two SOLO programs' stages from the clean LU sweep (<sweep_dir>/{off,on}/lu-p1-n512-b<B>-plru/stage_result.json; default
../lu-sweep-single-core-20261008). Every window, solo and pair, is the first and only window after a fresh FPGA reprogram,
so the board history behind them is the same. One run per arm: there is NO spread, so a difference of about 1% or less
in the pair, or a repaired fraction near 0, cannot be called an effect.

Definitions (TASK 015 section 2.3, definition B: the solo terms stay at their OFF values):
    S_off     = solo_A_off + solo_B_off                      what the two programs cost alone, SBC off
    I_off     = pair_off - S_off                             interference the sharing causes with SBC off
    I_on      = pair_on  - S_off                             the same with SBC on
    repaired  = (I_off - I_on) / I_off = (pair_off - pair_on) / I_off
    own_gain  = (solo_A_off - solo_A_on) + (solo_B_off - solo_B_on)   what SBC already does for each program ALONE
    excess    = (pair_off - pair_on) - own_gain              SBC's gain in the pair beyond its solo gains
    repaired_excess = excess / I_off                         the part that is specific to repairing interference
Computed for memAcc (memReads + memWrites, also reads and writes separately) and for L2 cycles (the window's run time).

Caveats printed in the table: (1) the pair window starts ONE shell, the two solo windows started two, so the pair is
expected to be a little cheaper than the sum of the solos by about one shell start (tens of thousands of accesses,
under 0.5% of the sum), the same in OFF and ON; (2) the programs' reports go to files in the pair and to the console
in the solo windows (about 1 KB each, negligible); (3) accessA of the pair is NOT expected to equal the sum of the
solos: the time-shared 8 KB L1 thrashes, so L1 misses (= L2 accesses) rise; only pair OFF vs pair ON must match.
"""
import csv, json, os, sys

pair_dir = sys.argv[1]
sweep_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(pair_dir.rstrip("/")), "lu-sweep-single-core-20261008")
LABEL = "lupair-p1-n512-b32+b128-plru"
BA, BB = 32, 128
SOLO = {BA: "lu-p1-n512-b%d-plru" % BA, BB: "lu-p1-n512-b%d-plru" % BB}
NOISE_PCT = 0.865   # % of memAcc: the ONE fresh-boot OFF replicate we have (LU n=768 b=128, two boots): 32,162,792 vs 31,887,029
os.makedirs(os.path.join(pair_dir, "results"), exist_ok=True)


def load(path):
    try:
        j = json.load(open(path))
    except (OSError, ValueError):
        return None
    return j if j.get("verdict") == "VALID" else None


pair = {ph: load(os.path.join(pair_dir, ph, LABEL, "stage_result.json")) for ph in ("off", "on")}
solo = {(b, ph): load(os.path.join(sweep_dir, ph, SOLO[b], "stage_result.json")) for b in (BA, BB) for ph in ("off", "on")}


def mem(c):
    return c["memReads"] + c["memWrites"]


def hit(c):
    return 100.0 * (c["primaryHit"] + c["secondaryHit"]) / c["accessA"]


def pct(x, base):
    return 100.0 * x / base if base else float("nan")


def f0(x):
    return format(int(x), ",") if isinstance(x, (int, float)) and x == x else "-"


def fd(x):
    return format(int(x), "+,") if isinstance(x, (int, float)) and x == x else "-"


def fp(x, d=2):
    return ("%+.*f%%" % (d, x)) if isinstance(x, (int, float)) and x == x else "-"


def fq(x, d=2):
    return ("%.*f" % (d, x)) if isinstance(x, (int, float)) and x == x else "-"


C = {k: (v["counters"] if v else None) for k, v in list(pair.items()) + [(("s", b, ph), solo[(b, ph)]) for b in (BA, BB) for ph in ("off", "on")]}
P_OFF, P_ON = C["off"], C["on"]
SA_OFF, SA_ON, SB_OFF, SB_ON = C[("s", BA, "off")], C[("s", BA, "on")], C[("s", BB, "off")], C[("s", BB, "on")]
out, rows = [], []
out.append("# Single-core LU pair: SBC off vs on, two lu_ncb running together, every window on its own fresh boot\n")
out.append("Pair = `lu_ncb -p1 -n512 -b%d` and `lu_ncb -p1 -n512 -b%d` started together on the one core (the OS time-slices them), both run to "
           "completion, window closed when both have exited. Single core, PLRU, 256 KB 8-way L2, bitstream sha256 `5ace41250e7c5141…`. "
           "The solo rows are the clean LU sweep's windows (same harness steps, same bitstream, one fresh boot each). **One run per arm: no spread, "
           "so a difference of about 1%% or less is not an effect.** memAcc = memReads + memWrites. L2 cycles = the L2 clock (50 MHz) over the window.\n" % (BA, BB))

have_pair = P_OFF is not None and P_ON is not None
have_solo_off = SA_OFF is not None and SB_OFF is not None
have_solo_on = SA_ON is not None and SB_ON is not None
if not (P_OFF and P_ON):
    got = [ph.upper() for ph in ("off", "on") if pair[ph]]
    out.append("> **PARTIAL**: valid pair stages so far: %s. The OFF stage runs first, then the ON stage.\n" % (", ".join(got) if got else "none"))

# ── 1. the pair ──
out.append("## 1. The pair (b=%d + b=%d), OFF vs ON\n" % (BA, BB))
out.append("| metric | pair OFF | pair ON | change | change % |")
out.append("|---|--:|--:|--:|--:|")


def row(name, key=None, fn=None, fmt=f0):
    a = (fn(P_OFF) if fn else P_OFF[key]) if P_OFF else None
    b = (fn(P_ON) if fn else P_ON[key]) if P_ON else None
    d = (b - a) if (a is not None and b is not None) else None
    pc = pct(d, a) if d is not None else None
    if fmt is f0:
        out.append("| %s | %s | %s | %s | %s |" % (name, fmt(a), fmt(b), fd(d), fp(pc) if pc is not None else "-"))
    else:        # a rate in percent: show the change in percentage points, not a percent of a percent
        out.append("| %s | %s | %s | %s | - |" % (name, fmt(a), fmt(b), ("%+.2f pp" % d) if d is not None else "-"))


row("memReads", "memReads"); row("memWrites", "memWrites"); row("**memAcc (reads + writes)**", fn=mem)
row("accessA (work done)", "accessA"); row("hit rate %", fn=hit, fmt=lambda x: fq(x) if x is not None else "-")
row("primary hits", "primaryHit"); row("secondary hits", "secondaryHit"); row("migrations", "migrations")
row("L2 cycles (window run time)", "L2_Cycles")
if P_OFF: out.append("\nWindow seconds: OFF %.1f s" % (P_OFF["L2_Cycles"] / 50e6) + ("  ·  ON %.1f s" % (P_ON["L2_Cycles"] / 50e6) if P_ON else ""))
for ph in ("off", "on"):
    j = pair[ph]
    if j and j.get("reports") and len(j["reports"]) == 2:
        ra, rb = j["reports"]
        out.append("- %s: program b%d ran %.2f s, b%d ran %.2f s (each one's own 'total time without initialization'); overlap fraction %.3f" % (
            ph.upper(), BA, ra["total_us"] / 1e6, BB, rb["total_us"] / 1e6, j["overlap_frac"]))
if have_pair:
    wd = pct(P_ON["accessA"] - P_OFF["accessA"], P_OFF["accessA"])
    out.append("- same-work check, pair ON vs OFF accessA: %s%s" % (fp(wd), "" if abs(wd) <= 1.0 else "   **FLAG: more than 1%, the two arms did not do the same work**"))

# ── 2. the solos ──
out.append("\n## 2. The two programs alone (clean LU sweep, one fresh boot each)\n")
out.append("| program | arm | memReads | memWrites | memAcc | accessA | hit % | L2 cycles | seconds |")
out.append("|---|---|--:|--:|--:|--:|--:|--:|--:|")
for b, ph, c in ((BA, "OFF", SA_OFF), (BA, "ON", SA_ON), (BB, "OFF", SB_OFF), (BB, "ON", SB_ON)):
    if c:
        out.append("| b=%d | %s | %s | %s | %s | %s | %s | %s | %.1f |" % (b, ph, f0(c["memReads"]), f0(c["memWrites"]), f0(mem(c)), f0(c["accessA"]), fq(hit(c)), f0(c["L2_Cycles"]), c["L2_Cycles"] / 50e6))
    else:
        out.append("| b=%d | %s | - | - | - | - | - | - | - |" % (b, ph))

# ── 3. interference and repair ──
out.append("\n## 3. Interference and how much of it SBC repaired\n")
res = {}
if have_pair and have_solo_off:
    def block(name, getter):
        s_off = getter(SA_OFF) + getter(SB_OFF)
        p_off, p_on = getter(P_OFF), getter(P_ON)
        i_off, i_on = p_off - s_off, p_on - s_off
        r = {"name": name, "S_off": s_off, "pair_off": p_off, "pair_on": p_on, "I_off": i_off, "I_on": i_on,
             "I_off_pct_of_S": pct(i_off, s_off), "repaired": (i_off - i_on) / i_off if i_off else float("nan")}
        if have_solo_on:
            own = (getter(SA_OFF) - getter(SA_ON)) + (getter(SB_OFF) - getter(SB_ON))
            r.update({"own_gain": own, "excess": (p_off - p_on) - own, "repaired_excess": ((p_off - p_on) - own) / i_off if i_off else float("nan")})
        res[name] = r
        return r
    block("memAcc", mem); block("memReads", lambda c: c["memReads"]); block("memWrites", lambda c: c["memWrites"]); block("L2 cycles", lambda c: c["L2_Cycles"])
    out.append("| quantity | S_off = solo A + solo B | pair OFF | pair ON | I_off = pair OFF − S_off | I_off / S_off | I_on = pair ON − S_off | **repaired** = (I_off − I_on) / I_off |")
    out.append("|---|--:|--:|--:|--:|--:|--:|--:|")
    for r in res.values():
        out.append("| %s | %s | %s | %s | %s | %s | %s | **%s** |" % (r["name"], f0(r["S_off"]), f0(r["pair_off"]), f0(r["pair_on"]), fd(r["I_off"]),
                                                                  fp(r["I_off_pct_of_S"]), fd(r["I_on"]), fp(100 * r["repaired"]) if r["repaired"] == r["repaired"] else "-"))
    if have_solo_on:
        out.append("\nBeyond what each program already gets from SBC alone (own_gain = the two solo gains, OFF − ON; excess = pair gain − own_gain):\n")
        out.append("| quantity | own_gain (solo A + solo B) | pair gain (OFF − ON) | excess | **repaired_excess** = excess / I_off |")
        out.append("|---|--:|--:|--:|--:|")
        for r in res.values():
            out.append("| %s | %s | %s | %s | **%s** |" % (r["name"], fd(r["own_gain"]), fd(r["pair_off"] - r["pair_on"]), fd(r["excess"]),
                                                       fp(100 * r["repaired_excess"]) if r["repaired_excess"] == r["repaired_excess"] else "-"))
    m = res["memAcc"]
    out.append("- accessA, sum of the solos (OFF) %s vs the pair (OFF) %s (%s): the time-shared L1 re-misses after each switch, so a little more is expected; this is not a same-work check."
               % (f0(SA_OFF["accessA"] + SB_OFF["accessA"]), f0(P_OFF["accessA"]), fp(pct(P_OFF["accessA"] - SA_OFF["accessA"] - SB_OFF["accessA"], SA_OFF["accessA"] + SB_OFF["accessA"]))))
    out.append("- hit rate: b=%d alone %s%%, b=%d alone %s%%, pair OFF %s%% -> ON %s%%" % (BA, fq(hit(SA_OFF)), BB, fq(hit(SB_OFF)), fq(hit(P_OFF)), fq(hit(P_ON))))
    # What one run per arm can resolve: the one fresh-boot replicate differs by NOISE_PCT of memAcc.
    noise = NOISE_PCT / 100.0 * P_OFF["memReads"] + NOISE_PCT / 100.0 * P_OFF["memWrites"]
    out.append("\n**Resolution of this measurement.** The only fresh-boot replicate we have (LU n=768, two boots) differs by %.2f%% of memAcc; for this pair that is about %s accesses." % (NOISE_PCT, f0(noise)))
    if m["I_off"] > 0:
        out.append("Against an interference of %s accesses that is about **%.0f percentage points** of any repaired fraction: a repaired fraction within that distance of 0 cannot be told from nothing." % (f0(m["I_off"]), 100.0 * noise / m["I_off"]))
    if m["I_off"] <= 2 * noise:
        out.append("\n**Verdict: not readable.** The interference (%s accesses) is not more than twice the noise (%s accesses), so the repaired fraction is not interpretable. "
                   "The OFF-vs-ON change of the pair itself (%s) is still a measured number, but it cannot be split into repair and SBC's own gains." % (fd(m["I_off"]), f0(noise), fp(pct(m["pair_on"] - m["pair_off"], m["pair_off"]))))
    elif "repaired_excess" in m:
        x = 100 * m["repaired_excess"]
        band = "below 10%: SBC does not repair the interference here" if x < 10 else ("10-25%: weak, needs repeats before it is believed" if x < 25 else "25% or more: SBC repairs a real part of the interference")
        out.append("\n**Verdict** (bands written before the run, applied to the fraction BEYOND the solos' own gains, because the TASK-definition fraction above also counts the %s accesses "
                   "SBC saves for b=%d alone): repaired_excess = **%s** (%s); the TASK-definition repaired fraction is %s." % (f0(m["own_gain"]), BB, fp(x), band, fp(100 * m["repaired"])))
else:
    out.append("(needs a valid pair OFF and ON stage and both solo OFF stages)")

# ── provenance ──
out.append("\n## Provenance\n")
for ph in ("off", "on"):
    j = pair[ph]
    out.append("- pair %s: %s" % (ph.upper(), ("valid, transcript `%s/%s/%s`" % (ph, LABEL, os.path.basename(j["log"]))) if j else "no valid stage yet"))
    if j and j.get("warnings"):
        for w in j["warnings"]:
            out.append("  - warning: %s" % w)
nf = len(os.listdir(os.path.join(pair_dir, "failed"))) if os.path.isdir(os.path.join(pair_dir, "failed")) else 0
out.append("- void attempts kept under `failed/`: %d" % nf)
out.append("- solo windows: from `%s` (one fresh boot each, checker v2). `PLAN.md` has the method, the harness diff and the predictions written before the run." % os.path.basename(sweep_dir))

# ── csv ──
fields = ["quantity", "S_off", "pair_off", "pair_on", "I_off", "I_off_pct_of_S", "I_on", "repaired", "own_gain", "excess", "repaired_excess"]
with open(os.path.join(pair_dir, "results", "results.csv"), "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
    w.writeheader()
    for r in res.values():
        w.writerow(dict(r, quantity=r["name"]))
open(os.path.join(pair_dir, "results", "table.md"), "w").write("\n".join(out) + "\n")
print("\n".join(out))
