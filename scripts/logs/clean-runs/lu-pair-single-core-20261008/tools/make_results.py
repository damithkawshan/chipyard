#!/usr/bin/env python3
"""Write RESULTS.md (the results log) and results/numbers.json for the single-core LU-pair test.

usage: make_results.py [<pair_dir>]

RESULTS.md holds results only (no Q&A, no explanations): setup, one row per window, the summary, the verdict, short caveats.
Re-run it after every run; the structure stays the same. Reads the VALID pair stages of run 1 (<pair_dir>/{off,on}/<label>/
stage_result.json) and of every repeat (<pair_dir>/r2/..., r3/...), plus the solo stages of the clean LU sweep. Fills
tools/RESULTS.template.md ({{name}} placeholders). Every number on the page is computed here; none is typed by hand.

Terms (the TASK 015 ones):
    memory accesses = memReads + memWrites (DRAM reads + writes seen by the L2)
    baseline        = the two programs run alone (solo b=32 + solo b=128, clean sweep windows), for the same SBC setting
    pair            = the two programs run together (mean over the valid runs)
    interference    = pair - baseline, per SBC setting
    recovered       = interference(off) - interference(on)          share = recovered / interference(off)
Noise: each window's traffic is drawn with a relative sd estimated from every repeat we have (the n=768 OFF replicate, and the
pair's own repeats when they exist); the 16-84% range of the share comes from 200,000 draws. A rough guide (few degrees of
freedom), not a confidence interval.
"""
import datetime, json, os, re, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
pair_dir = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(HERE)
sweep_dir = os.path.join(os.path.dirname(pair_dir), "lu-sweep-single-core-20261008")
LABEL = "lupair-p1-n512-b32+b128-plru"
BA, BB = 32, 128
SOLO = {b: "lu-p1-n512-b%d-plru" % b for b in (BA, BB)}
N768_REPLICATE = (32162792, 31887029)   # LU n=768 b=128 OFF, two fresh boots (sweep failed/ attempt 031826 vs the valid stage)
BANDS = [(10.0, "below 10%", "no real recovery"),
         (25.0, "10-25%", "weak, repeat before believing"),
         (1e9, "25% or more", "real recovery")]


def load(path):
    try:
        j = json.load(open(path))
    except (OSError, ValueError):
        return None
    return j if j.get("verdict") == "VALID" else None


def mem(c):
    return c["memReads"] + c["memWrites"]


def M(x, d=2):
    return "%.*f" % (d, x / 1e6)


def SM(x, d=2):                       # signed millions
    return "%+.*f" % (d, x / 1e6)


def SP(x, d=1):                       # signed percent
    return "%+.*f%%" % (d, x)


def P(x, d=0):
    return "%.*f" % (d, x)


def n0(x):
    return format(int(round(x)), ",")


def started(j):
    m = re.search(r"_(\d{8})-(\d{6})\.log$", j.get("log", ""))
    return "%s-%s %s:%s" % (m.group(1)[4:6], m.group(1)[6:8], m.group(2)[:2], m.group(2)[2:4]) if m else "-"


def status_start(status_file, ph):
    """Start time (MM-DD HH:MM) of the last STAGE-START of a phase in a launcher status file, or None."""
    t = None
    try:
        for ln in open(status_file, errors="replace"):
            m = re.match(r"STAGE-START %s \S+ attempt=\d+ (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d)" % ph, ln)
            if m:
                t = "%s-%s %s:%s" % (m.group(2), m.group(3), m.group(4), m.group(5))
    except OSError:
        pass
    return t


# ───────────── load runs ─────────────
run_dirs = [("run 1", pair_dir)] + [("run %s" % t[1:], os.path.join(pair_dir, t))
                                    for t in sorted(os.listdir(pair_dir), key=lambda s: (len(s), s)) if re.fullmatch(r"r\d+", t)]
runs = []
for name, d in run_dirs:
    off = load(os.path.join(d, "off", LABEL, "stage_result.json"))
    on = load(os.path.join(d, "on", LABEL, "stage_result.json"))
    status_file = os.path.join(d, "chain_status.txt")
    finished = os.path.exists(status_file) and "CHAIN FINISHED" in open(status_file, errors="replace").read()
    runs.append({"name": name, "dir": d, "off": off, "on": on, "finished": finished, "started": os.path.exists(status_file), "status_file": status_file})
good = [r for r in runs if r["off"] and r["on"]]
if not good:
    sys.exit("no run has both a valid OFF and a valid ON stage yet")
solo = {(b, ph): load(os.path.join(sweep_dir, ph, SOLO[b], "stage_result.json")) for b in (BA, BB) for ph in ("off", "on")}
if any(v is None for v in solo.values()):
    sys.exit("a solo stage of the sweep is missing: %s" % [k for k, v in solo.items() if v is None])
SC = {k: v["counters"] for k, v in solo.items()}


def numbers(po, pn):
    """po, pn: pair OFF / ON counters (dicts)."""
    A = mem(SC[(BA, "off")]) + mem(SC[(BB, "off")])      # baseline, SBC off
    B = mem(SC[(BA, "on")]) + mem(SC[(BB, "on")])        # baseline, SBC on
    C, D = mem(po), mem(pn)                              # pair off / on
    i_off, i_on = C - A, D - B
    rec = i_off - i_on
    return {"base_off": A, "base_on": B, "pair_off": C, "pair_on": D, "intf_off": i_off, "intf_on": i_on, "recovered": rec,
            "share": 100.0 * rec / i_off, "intf_off_pct": 100.0 * i_off / A, "intf_on_pct": 100.0 * i_on / B,
            "base_chg": B - A, "base_chg_pct": 100.0 * (B - A) / A, "pair_chg": D - C, "pair_chg_pct": 100.0 * (D - C) / C,
            "task_def": 100.0 * (C - D) / i_off}


def mean_counters(cs):
    return {k: sum(c[k] for c in cs) / len(cs) for k in cs[0]}


run_numbers = [numbers(r["off"]["counters"], r["on"]["counters"]) for r in good]
mo = mean_counters([r["off"]["counters"] for r in good])
mn = mean_counters([r["on"]["counters"] for r in good])
N = numbers(mo, mn) if len(good) > 1 else run_numbers[0]

# ───────────── noise and the 16-84% range of the share ─────────────
# Alone windows: the only repeat we have is LU n=768 (two fresh boots). Pair windows: this pair's own repeats, when they exist.
def pooled(groups):
    num = den = 0.0
    for g in groups:
        g = np.array(g, float)
        num += (len(g) - 1) * np.var(g, ddof=1) / g.mean() ** 2
        den += len(g) - 1
    return float(np.sqrt(num / den)), int(den)


sigma_solo, _ = pooled([list(N768_REPLICATE)])
if len(good) > 1:
    sigma_pair, dof = pooled([[mem(r["off"]["counters"]) for r in good], [mem(r["on"]["counters"]) for r in good]])
    sigma_pair_src = "pair repeats, %d degree%s of freedom" % (dof, "" if dof == 1 else "s")
else:
    sigma_pair, dof, sigma_pair_src = sigma_solo, 1, "assumed equal to alone"
rng = np.random.default_rng(1)
K = 200000


def draw(v, sg, k=1):
    return v * (1 + sg * rng.standard_normal((K, k)))


po_d = np.mean(draw(1.0, sigma_pair, len(good)) * np.array([mem(r["off"]["counters"]) for r in good]), axis=1)
pn_d = np.mean(draw(1.0, sigma_pair, len(good)) * np.array([mem(r["on"]["counters"]) for r in good]), axis=1)
s = {key: draw(float(mem(SC[key])), sigma_solo, 1)[:, 0] for key in SC}
i_off_d = po_d - (s[(BA, "off")] + s[(BB, "off")])
rec_d = (po_d - pn_d) - ((s[(BA, "off")] - s[(BA, "on")]) + (s[(BB, "off")] - s[(BB, "on")]))
lo, hi = np.percentile(100.0 * rec_d / i_off_d, [16, 84])
sigma = sigma_solo
share = N["share"]
band_i = next(i for i, b in enumerate(BANDS) if share < b[0])
band_lo = next(i for i, b in enumerate(BANDS) if lo < b[0])
band_hi = next(i for i, b in enumerate(BANDS) if hi < b[0])
settled = "settled" if band_lo == band_hi else "not settled, also touches %s" % " and ".join(
    '"%s"' % BANDS[i][1] for i in range(band_lo, band_hi + 1) if i != band_i)

# ───────────── run time (model) ─────────────
T, R = mo["L2_Cycles"], mo["memReads"]
dT, dR = mn["L2_Cycles"] - mo["L2_Cycles"], mn["memReads"] - mo["memReads"]
LR0 = 38


def runtime_change(lr):
    return 100.0 * (dT + dR * (lr - LR0)) / (T + R * (lr - LR0))


rt = ["| DRAM read cost (L2 cycles) | pair run time, off to on |", "|--:|--:|", "| %d (measured on this board) | %+.2f%% |" % (LR0, runtime_change(LR0))]
rt += ["| %d (model) | %+.2f%% |" % (lr, runtime_change(lr)) for lr in (100, 200, 300)]

# ───────────── window log: one row per window ─────────────
HL = "hit rate"


def hit(c):
    return 100.0 * (c["primaryHit"] + c["secondaryHit"]) / c["accessA"]


def wrow(label, arm, j, state):
    if j:
        c = j["counters"]
        return "| %s | %s | %s | %s | %s | %s | %.2f%% | %.1f | %s |" % (label, arm, started(j), n0(c["memReads"]), n0(c["memWrites"]), n0(mem(c)), hit(c),
                                                                      c["L2_Cycles"] / 50e6, state)
    return "| %s | %s | %s | - | - | - | - | - | %s |" % (label, arm, state[1] if isinstance(state, tuple) else "-", state[0] if isinstance(state, tuple) else state)


win = ["| window | SBC | started | memory reads | memory writes | memory accesses | L2 hit rate | seconds | status |", "|---|---|---|--:|--:|--:|--:|--:|---|"]
for b in (BA, BB):
    for ph in ("off", "on"):
        win.append(wrow("alone b=%d" % b, ph.replace("off", "off").replace("on", "on"), solo[(b, ph)], "valid (sweep)"))
for r in runs:
    for ph in ("off", "on"):
        if r[ph]:
            win.append(wrow("pair %s" % r["name"], ph, r[ph], "valid"))
        else:
            st = status_start(r["status_file"], ph)
            win.append(wrow("pair %s" % r["name"], ph, None, ("running", st) if (st and r["started"] and not r["finished"]) else ("pending", "-")))

# ───────────── per-run table (only with a repeat) ─────────────
per_run = ""
if len(good) > 1:
    rr = ["| | " + " | ".join(r["name"] for r in good) + " |", "|---|" + "--:|" * len(good)]
    for label, fn in (("Pair, SBC off (M)", lambda n: M(n["pair_off"])), ("Pair, SBC on (M)", lambda n: M(n["pair_on"])),
                      ("Interference, SBC off (M)", lambda n: SM(n["intf_off"])), ("Interference, SBC on (M)", lambda n: SM(n["intf_on"])),
                      ("Recovered (M)", lambda n: M(n["recovered"])), ("**Recovered, % of interference**", lambda n: "**%s%%**" % P(n["share"]))):
        rr.append("| %s | " % label + " | ".join(fn(n) for n in run_numbers) + " |")
    sh = [n["share"] for n in run_numbers]
    po_ = [mem(r["off"]["counters"]) for r in good]
    pn_ = [mem(r["on"]["counters"]) for r in good]
    spread = lambda v: 100.0 * (max(v) - min(v)) / (sum(v) / len(v))
    rec_ = [n["recovered"] for n in run_numbers]
    per_run = "## Per run\n\n" + "\n".join(rr) + "\n\n- Recovered share: %s, a difference of %.0f percentage points\n- Pair traffic differs between runs by %.2f%% (SBC off) and %.2f%% (SBC on)\n- SBC-on difference between runs: %.2f M; recovered amount: %.2f–%.2f M\n" % (
        " and ".join("%.0f%%" % x for x in sh), max(sh) - min(sh), spread(po_), spread(pn_), (max(pn_) - min(pn_)) / 1e6, min(rec_) / 1e6, max(rec_) / 1e6)

# ───────────── status ─────────────
now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
inprog = [r for r in runs if r["started"] and not r["finished"] and not (r["off"] and r["on"])]
done_names = ", ".join(r["name"] for r in good)
status = ("%s done, %s (repeat) running" % (done_names, ", ".join(r["name"] for r in inprog))) if inprog else "DONE, %d run(s)" % len(good)
mean_note = "mean of %d runs" % len(good) if len(good) > 1 else "run 1 only"

val = {
    "status": status, "updated": now, "mean_note": mean_note, "windows_table": "\n".join(win), "per_run_section": per_run,
    "base_off": M(N["base_off"]), "base_on": M(N["base_on"]), "pair_off": M(N["pair_off"]), "pair_on": M(N["pair_on"]),
    "base_chg": SM(N["base_chg"]), "base_chg_pct": SP(N["base_chg_pct"]), "pair_chg": SM(N["pair_chg"]), "pair_chg_pct": SP(N["pair_chg_pct"]),
    "intf_off": SM(N["intf_off"]), "intf_on": SM(N["intf_on"]), "intf_chg": SM(-N["recovered"]), "intf_chg_pct": "-%s%%" % P(N["share"]),
    "intf_off_pct": SP(N["intf_off_pct"]), "intf_on_pct": SP(N["intf_on_pct"]),
    "intf_pp": "%+.1f percentage points" % (N["intf_on_pct"] - N["intf_off_pct"]),
    "rec_M": M(N["recovered"]), "share": P(N["share"]), "share_lo": P(lo), "share_hi": P(hi),
    "band": BANDS[band_i][1], "band_word": BANDS[band_i][2], "settled": settled,
    "runtime_table": "\n".join(rt), "rt38": "%+.2f%%" % runtime_change(LR0),
    "sigma_solo": "%.1f%%" % (100 * sigma_solo), "sigma_pair": "%.1f%%" % (100 * sigma_pair), "sigma_pair_src": sigma_pair_src,
    "access_extra": P(100.0 * (mo["accessA"] / (SC[(BA, "off")]["accessA"] + SC[(BB, "off")]["accessA"]) - 1)),
}

tmpl = open(os.path.join(HERE, "RESULTS.template.md")).read()
missing = sorted(set(re.findall(r"\{\{(\w+)\}\}", tmpl)) - set(val))
if missing:
    sys.exit("template placeholders without a value: %s" % missing)
page = re.sub(r"\{\{(\w+)\}\}", lambda m: val[m.group(1)], tmpl)
page = re.sub(r"\n{3,}", "\n\n", page)
open(os.path.join(pair_dir, "RESULTS.md"), "w").write(page)
os.makedirs(os.path.join(pair_dir, "results"), exist_ok=True)
with open(os.path.join(pair_dir, "results", "numbers.json"), "w") as fh:
    json.dump({"runs_used": [r["name"] for r in good], "mean_numbers": N, "per_run": run_numbers, "sigma_rel_solo": sigma_solo, "sigma_rel_pair": sigma_pair, "dof_pair": dof,
               "share_range_16_84": [float(lo), float(hi)], "runtime_change_pct": {str(lr): runtime_change(lr) for lr in (38, 100, 200, 300)}},
              fh, indent=1, default=float)
print("wrote RESULTS.md and results/numbers.json  (runs used: %s; recovered %.1f%%, 16-84%% range %.0f-%.0f%%, sigma alone %.2f%%, pair %.2f%%)"
      % (", ".join(r["name"] for r in good), share, lo, hi, 100 * sigma_solo, 100 * sigma_pair))
