#!/usr/bin/env python3
"""Write RESULTS.md (results only) and results/numbers.json for the LU pair search.

usage: make_results.py [<search_dir>]

Reads the VALID stages <search_dir>/{off,on}/lupair-p1-n512-b<A>+b<B>-plru/stage_result.json, the solo baselines of the clean LU
sweep (n=512), the model predictions fixed in model/results/predictions_v1.txt, and chain_status.txt (for running / pending rows).
Every number is computed here. Terms (TASK 015): memory accesses = DRAM reads + writes seen by the L2; baseline = the two programs
alone, same SBC setting; interference = pair - baseline; recovered = interference(off) - interference(on).
"""
import datetime, json, os, re, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(HERE)
CLEAN = os.path.dirname(S)
SWEEP = os.path.join(CLEAN, "lu-sweep-single-core-20261008")
PAIRTEST = os.path.join(CLEAN, "lu-pair-single-core-20261008")
PREDS = os.path.join(S, "model", "results", "predictions_v1.txt")
BANDS = [(10.0, "below 10%", "no real recovery"), (25.0, "10-25%", "weak, repeat before believing"), (1e9, "25% or more", "real recovery")]
N768 = (32162792, 31887029)           # LU n=768 b=128 SBC off, two fresh boots
ORDER = [(64, 64), (32, 32), (64, 256), (64, 128), (128, 128)]     # the planned windows, in PLAN.md order


def label(a, b):
    return "lupair-p1-n512-b%d+b%d-plru" % (a, b)


def load(path):
    try:
        j = json.load(open(path))
    except (OSError, ValueError):
        return None
    return j if j.get("verdict") == "VALID" else None


def mem(c):
    return c["memReads"] + c["memWrites"]


def hit(c):
    return 100.0 * (c["primaryHit"] + c["secondaryHit"]) / c["accessA"]


def M(x, d=2):
    return "%.*f" % (d, x / 1e6)


def SM(x, d=2):
    return "%+.*f" % (d, x / 1e6)


def SP(x, d=1):
    return "%+.*f%%" % (d, x)


def n0(x):
    return format(int(round(x)), ",")


def started(j):
    m = re.search(r"_(\d{8})-(\d{6})\.log$", j.get("log", ""))
    return "%s-%s %s:%s" % (m.group(1)[4:6], m.group(1)[6:8], m.group(2)[:2], m.group(2)[2:4]) if m else "-"


# ───────────── inputs ─────────────
pairs_seen = []
for ph in ("off", "on"):
    d = os.path.join(S, ph)
    for lab in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        m = re.fullmatch(r"lupair-p1-n512-b(\d+)\+b(\d+)-plru", lab)
        if m and os.path.exists(os.path.join(d, lab, "stage_result.json")):
            pr = (int(m.group(1)), int(m.group(2)))
            if pr not in pairs_seen:
                pairs_seen.append(pr)
planned = [p for p in ORDER if p in pairs_seen] + [p for p in ORDER if p not in pairs_seen] + [p for p in pairs_seen if p not in ORDER]
stage = {(p, ph): load(os.path.join(S, ph, label(*p), "stage_result.json")) for p in planned for ph in ("off", "on")}
solo = {(b, ph): load(os.path.join(SWEEP, ph, "lu-p1-n512-b%d-plru" % b, "stage_result.json")) for b in (32, 64, 128, 256) for ph in ("off", "on")}
if any(v is None for v in solo.values()):
    sys.exit("a solo sweep window is missing")
SC = {k: v["counters"] for k, v in solo.items()}

pred = {}
if os.path.exists(PREDS):
    for ln in open(PREDS):
        m = re.match(r"b(\d+)\s*\+\s*b(\d+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+) /\s*([\d.]+) /\s*([\d.]+)\s*\|", ln)
        if m:
            pred[(int(m.group(1)), int(m.group(2)))] = (float(m.group(4)) * 1e6, float(m.group(5)) * 1e6, float(m.group(6)) * 1e6)

# chain status: what is running / pending
status_text = open(os.path.join(S, "chain_status.txt"), errors="replace").read() if os.path.exists(os.path.join(S, "chain_status.txt")) else ""
last_stages = re.findall(r'CHAIN-START .* STAGES="([^"]*)"', status_text)
want = last_stages[-1].split() if last_stages else []
running = {}
for m in re.finditer(r"STAGE-START (off|on) (\S+) attempt=\d+ (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d)", status_text):
    running[(m.group(1), m.group(2))] = "%s-%s %s:%s" % (m.group(4), m.group(5), m.group(6), m.group(7))
ok_set = {(m.group(1), m.group(2)) for m in re.finditer(r"STAGE-OK (off|on) (\S+)", status_text)}

# ───────────── windows ─────────────
win = ["| pair | SBC | started | memory reads | memory writes | memory accesses | change vs SBC off | L2 hit rate | program times (s) | status |",
       "|---|---|---|--:|--:|--:|--:|--:|--:|---|"]
n_valid = 0
n_open = 0                                                             # running or pending rows
for p in planned:
    for ph in ("off", "on"):
        j = stage[(p, ph)]
        if j:
            n_valid += 1
            c = j["counters"]
            tm = " / ".join("%.1f" % (r["total_us"] / 1e6) for r in j.get("reports", [])) or "-"
            joff = stage[(p, "off")]
            chg = "%s M (%s)" % (SM(mem(c) - mem(joff["counters"])), SP(100.0 * (mem(c) - mem(joff["counters"])) / mem(joff["counters"]))) if (ph == "on" and joff) else "-"
            win.append("| b%d + b%d | %s | %s | %s | %s | %s | %s | %.2f%% | %s | valid |" % (p[0], p[1], ph, started(j), n0(c["memReads"]), n0(c["memWrites"]), n0(mem(c)), chg, hit(c), tm))
        elif "%s:%d,%d" % (ph, p[0], p[1]) in want:
            k = (ph, label(*p))
            st = running.get(k)
            state = "running" if (st and k not in ok_set) else "pending"
            n_open += 1
            win.append("| b%d + b%d | %s | %s | - | - | - | - | - | - | %s |" % (p[0], p[1], ph, st if state == "running" else "-", state))

# ───────────── interference, SBC off ─────────────
def base(p, ph):
    return mem(SC[(p[0], ph)]) + mem(SC[(p[1], ph)])


done_off = [p for p in planned if stage[(p, "off")]]
itab = ["| pair | baseline (M) | pair (M) | interference (M) | % of baseline | predicted (M): median (min–max) | within range |", "|---|--:|--:|--:|--:|--:|--:|"]
meas = {}
for p in done_off:
    A, C = base(p, "off"), mem(stage[(p, "off")]["counters"])
    meas[p] = (C - A, 100.0 * (C - A) / A)
    pr = pred.get(p)
    ptxt = "%s (%s–%s)" % (M(pr[1]), M(pr[0]), M(pr[2])) if pr else "-"
    inr = ("yes" if pr[0] <= C - A <= pr[2] else ("above" if C - A > pr[2] else "below")) if pr else "-"
    itab.append("| b%d + b%d | %s | %s | **%s** | %s | %s | %s |" % (p[0], p[1], M(A), M(C), SM(C - A), SP(meas[p][1]), ptxt, inr))
itab_txt = "\n".join(itab) if done_off else "(no SBC-off window yet)"

# ───────────── pre-registered checks ─────────────
def have(*ps):
    return all(q in meas for q in ps)


chk = []
five = [p for p in ORDER]
if have(*five):
    top = max(five, key=lambda q: meas[q][0])
    others = [q for q in five if q != (64, 64)]
    chk.append("- P1 b64+b64 largest of the five, at least 3.0 M: **%s** (%.2f M; largest is b%d+b%d)" % ("pass" if top == (64, 64) and meas[(64, 64)][0] >= 3.0e6 else "fail", meas[(64, 64)][0] / 1e6, top[0], top[1]))
    chk.append("- P2 b64+b64 at least 1.5× every other pair: **%s** (smallest ratio %.2f)" % ("pass" if all(meas[(64, 64)][0] >= 1.5 * meas[q][0] for q in others) else "fail", min(meas[(64, 64)][0] / meas[q][0] for q in others)))
    top_pct = max(five, key=lambda q: meas[q][1])
    chk.append("- P3 b32+b32 largest in %% of baseline, at least +58%%: **%s** (%s; largest is b%d+b%d)" % ("pass" if top_pct == (32, 32) and meas[(32, 32)][1] >= 58 else "fail", SP(meas[(32, 32)][1], 0), top_pct[0], top_pct[1]))
    chk.append("- P4 b64+b256 between b64+b64 and b64+b128, 1.2–3.8 M: **%s** (%.2f M)" % ("pass" if meas[(64, 128)][0] <= meas[(64, 256)][0] <= meas[(64, 64)][0] and 1.2e6 <= meas[(64, 256)][0] <= 3.8e6 else "fail", meas[(64, 256)][0] / 1e6))
    chk.append("- P5 b128+b128 at most 1.7 M: **%s** (%.2f M)" % ("pass" if meas[(128, 128)][0] <= 1.7e6 else "fail", meas[(128, 128)][0] / 1e6))
    chk.append("- Wrong if b64+b64 is below 2 M or another pair is above it: **%s**" % ("wrong" if meas[(64, 64)][0] < 2.0e6 or top != (64, 64) else "not triggered"))
else:
    left = [q for q in five if q not in meas]
    chk.append("- not complete: waiting for %s" % ", ".join("b%d+b%d" % q for q in left))
    if meas:
        chk.append("- so far: " + ", ".join("b%d+b%d %s M (%s)" % (q[0], q[1], M(meas[q][0]), SP(meas[q][1], 0)) for q in sorted(meas, key=lambda q: -meas[q][0])))

# ───────────── SBC recovered (pairs with both arms) ─────────────
def pooled(groups):
    num = den = 0.0
    for g in groups:
        g = np.array(g, float)
        num += (len(g) - 1) * np.var(g, ddof=1) / g.mean() ** 2
        den += len(g) - 1
    return (float(np.sqrt(num / den)), int(den)) if den else (None, 0)


sigma_solo, _ = pooled([list(N768)])                                  # alone windows: the one repeat we have (LU n=768)
b3 = [load(os.path.join(d, "off", label(32, 128), "stage_result.json")) for d in (PAIRTEST, os.path.join(PAIRTEST, "r2"))]
b3on = [load(os.path.join(d, "on", label(32, 128), "stage_result.json")) for d in (PAIRTEST, os.path.join(PAIRTEST, "r2"))]
pg = ([[mem(j["counters"]) for j in b3]] if all(b3) else []) + ([[mem(j["counters"]) for j in b3on]] if all(b3on) else [])
sigma_pair, dof_pair = pooled(pg) if pg else (None, 0)
if sigma_pair is None:
    sigma_pair = sigma_solo                                           # no pair repeat yet: assume the same as alone
den = dof_pair
sigma = sigma_solo
rng = np.random.default_rng(1)
K = 200000
rows, sbc = ["| pair | interference off (M) | interference on (M) | recovered (M) | recovered, % of interference | noise range | band |", "|---|--:|--:|--:|--:|--:|---|"], {}
for p in planned:
    if not (stage[(p, "off")] and stage[(p, "on")]):
        continue
    po, pn = mem(stage[(p, "off")]["counters"]), mem(stage[(p, "on")]["counters"])
    Aoff, Bon = base(p, "off"), base(p, "on")
    i_off, i_on = po - Aoff, pn - Bon
    rec = i_off - i_on
    share = 100.0 * rec / i_off
    dr = lambda v, sg: v * (1 + sg * rng.standard_normal(K))
    sd = {key: dr(float(mem(SC[key])), sigma_solo) for key in SC}
    so = lambda ph: sd[(p[0], ph)] + sd[(p[1], ph)]
    ioff_d = dr(float(po), sigma_pair) - so("off")
    rec_d = (dr(float(po), sigma_pair) - dr(float(pn), sigma_pair)) - (so("off") - so("on"))
    lo, hi = np.percentile(100.0 * rec_d / ioff_d, [16, 84])
    band = next(b for b in BANDS if share < b[0])
    sbc[p] = {"i_off": i_off, "i_on": i_on, "recovered": rec, "share": share, "lo": float(lo), "hi": float(hi)}
    rows.append("| b%d + b%d | %s | %s | %s | **%.0f%%** | %.0f–%.0f%% | %s: %s |" % (p[0], p[1], SM(i_off), SM(i_on), M(rec), share, lo, hi, band[1], band[2]))
sbc_txt = "\n".join(rows) if sbc else "(no pair has both a valid SBC-off and a valid SBC-on window yet)"

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
n_plan = n_valid + n_open
page = f"""# LU pair search: results

**Status:** {n_valid} of {n_plan} planned windows valid · updated {now}
Plan, logic and fixed predictions: [PLAN.md](PLAN.md) · model: [model/](model/) · numbers: [results/numbers.json](results/numbers.json)

## Windows

{chr(10).join(win) if len(win) > 2 else "(no window yet)"}

## Interference, SBC off

{itab_txt}

## Pre-registered checks

{chr(10).join(chk)}

## Recovered by SBC

{sbc_txt}

- Page-colour noise is not in the range above: b64 windows get other physical pages in pair and alone (model spread 0.4–0.5 M per b64 program, about ±1 M for a pair with b64; PLAN.md)
- Noise per window: {100 * sigma_solo:.1f}% alone (LU n=768 repeat), {100 * sigma_pair:.1f}% pair ({'b32+b128 pair repeats' if dof_pair else 'assumed equal to alone'})

## Caveats

- Baseline = single sweep windows (self-pairs use the same window twice)
- L2 counters cover both programs: no per-program attribution
- "Recovered" assumes SBC's baseline gain carries over to the pair

Nothing is committed.
"""
page = re.sub(r"\n{3,}", "\n\n", page)
open(os.path.join(S, "RESULTS.md"), "w").write(page)
os.makedirs(os.path.join(S, "results"), exist_ok=True)
json.dump({"interference_off": {"b%d+b%d" % p: {"M": meas[p][0], "pct": meas[p][1]} for p in meas}, "sbc": {"b%d+b%d" % p: v for p, v in sbc.items()}, "sigma_rel_solo": sigma_solo, "sigma_rel_pair": sigma_pair},
          open(os.path.join(S, "results", "numbers.json"), "w"), indent=1, default=float)
print("wrote RESULTS.md (%d valid windows; %d pairs with SBC-off, %d with both arms)" % (n_valid, len(meas), len(sbc)))
