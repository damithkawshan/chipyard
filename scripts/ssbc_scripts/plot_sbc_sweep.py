#!/usr/bin/env python3
"""Plot an SBC migrate=off vs migrate=on sweep from a run_parsec_session.exp CSV.

    python3 plot_sbc_sweep.py scripts/logs/lu_runs_20261001-193308.csv

Reads one row per run, keeps the rows that completed, averages the repeats of each
(point, migrate) pair, and draws what the switch did as a function of each knob the sweep
varied - matrix size n, block size b, thread count p - plus the victim policy.

The headline is memAcc = memReads + memWrites, the count of things that physically happened
at the memory port: the one number with no denominator to argue about. accessA is the
same-work check: where the OFF and ON halves of a point did not do comparable work, the
traffic and cycle deltas are a measurement artefact rather than an SBC effect, and those
points are ringed and excluded from the "best point" summary.

Writes <csv-stem>_sweep.png, <csv-stem>_policy.png (when more than one policy was run) and
<csv-stem>_summary.csv next to the input, and prints the same table to stdout.
"""

import argparse
import csv
import os
import sys
from collections import OrderedDict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ── palette ───────────────────────────────────────────────────────────────────────────────
# Categorical slots 1 and 2 of the reference palette, validated as a pair for the light
# surface: lightness band, chroma floor, CVD separation (worst adjacent dE 24.7 protan),
# normal-vision floor (33.6) and contrast all pass. Status colors are reserved for the
# same-work flag and never used as a series.
SURFACE   = "#fcfcfb"
INK       = "#0b0b0b"
INK_SOFT  = "#52514e"
INK_FAINT = "#9a9892"
S1        = "#2a78d6"   # blue   - migrate=off, and the first metric of a pair
S2        = "#eb6834"   # orange - migrate=on, and the second metric of a pair
CRITICAL  = "#d03b3b"   # reserved: the same-work violation flag

LINE_W   = 1.6          # ~2px
MARK_SZ  = 7            # ~9px
RING_W   = 1.5          # ~2px surface ring, so overlapping marks stay separable
SAME_WORK_TOL = 2.0     # percent

COUNTERS = [
    "migrations", "secHits", "secMiss", "attempted", "aborted", "parked", "dispDrop",
    "accessA", "primaryHit", "secondaryHit", "dataMiss", "memReads", "memWrites",
    "L2_Accesses", "L2_Hits", "L2_Cycles",
]


# ── loading ───────────────────────────────────────────────────────────────────────────────
def load(path):
    """-> OrderedDict label -> point, each with the mean counters of its OK runs per side."""
    sums, counts, meta = {}, {}, OrderedDict()
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            if row.get("status") != "OK":
                continue
            label, mig = row["label"], row["migrate"]
            meta.setdefault(label, {
                "label": label, "axis": row.get("axis", ""), "bench": row.get("bench", ""),
                "policy": row.get("policy", ""),
                "p": row.get("p", ""), "n": row.get("n", ""), "b": row.get("b", ""),
            })
            key = (label, mig)
            acc = sums.setdefault(key, dict.fromkeys(COUNTERS, 0.0))
            for c in COUNTERS:
                try:
                    acc[c] += float(row.get(c) or 0)
                except ValueError:
                    pass
            counts[key] = counts.get(key, 0) + 1

    points = OrderedDict()
    for label, m in meta.items():
        pt = dict(m)
        for mig in ("off", "on"):
            key = (label, mig)
            if key not in counts:
                continue
            pt[mig] = derive({c: sums[key][c] / counts[key] for c in COUNTERS})
            pt[mig + "_runs"] = counts[key]
        if "off" in pt and "on" in pt:
            points[label] = pt
    return points


def derive(c):
    """Add the metrics that are ratios of the raw counters."""
    c = dict(c)
    c["memAcc"] = c["memReads"] + c["memWrites"]
    c["hitRate"] = 100.0 * (c["primaryHit"] + c["secondaryHit"]) / c["accessA"] if c["accessA"] else None
    c["hitsPerPark"] = c["secHits"] / c["migrations"] if c["migrations"] else None
    c["abortRate"] = 100.0 * c["aborted"] / c["attempted"] if c["attempted"] else None
    return c


def delta(pt, key):
    """ON vs OFF, in percent. None when the baseline is zero or missing."""
    o, n = pt["off"].get(key), pt["on"].get(key)
    if not o or n is None:
        return None
    return 100.0 * (n - o) / o


def same_work(pt):
    d = delta(pt, "accessA")
    return d is not None and abs(d) <= SAME_WORK_TOL


# ── slicing the star sweep back into axes ─────────────────────────────────────────────────
def centre_of(points):
    for pt in points.values():
        if pt["axis"] == "centre":
            return pt
    return next(iter(points.values()), None)


def axis_slice(points, knob, centre):
    """The points that differ from the centre in `knob` alone, sorted by it."""
    fixed = [k for k in ("p", "n", "b") if k != knob]
    out = []
    for pt in points.values():
        if pt["policy"] != centre["policy"]:
            continue
        if any(pt[k] != centre[k] for k in fixed):
            continue
        try:
            pt = dict(pt, _x=int(pt[knob]))
        except (ValueError, TypeError):
            continue
        out.append(pt)
    out.sort(key=lambda q: q["_x"])
    return out if len(out) >= 2 else []


def policy_slice(points, centre):
    out = [pt for pt in points.values()
           if all(pt[k] == centre[k] for k in ("p", "n", "b"))]
    return out if len({pt["policy"] for pt in out}) >= 2 else []


# ── drawing ───────────────────────────────────────────────────────────────────────────────
def style(ax, title, ylabel):
    ax.set_facecolor(SURFACE)
    ax.set_title(title, fontsize=10, color=INK, pad=8, loc="left")
    ax.set_ylabel(ylabel, fontsize=9, color=INK_SOFT)
    ax.grid(axis="y", color="#e6e5e1", linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color("#d8d7d2")
    ax.tick_params(colors=INK_SOFT, labelsize=9)


def series(ax, xs, ys, color, label=None):
    """One line, thin, with ringed markers. Gaps where a value is missing."""
    ax.plot(xs, ys, color=color, linewidth=LINE_W, marker="o", markersize=MARK_SZ,
            markeredgecolor=SURFACE, markeredgewidth=RING_W, label=label, zorder=3)


def legend(ax):
    ax.legend(frameon=False, fontsize=8, labelcolor=INK_SOFT, loc="best",
              borderaxespad=0.6, handlelength=1.6)


def ref_line(ax, y, text):
    ax.axhline(y, color=INK_FAINT, linewidth=1.0, linestyle=(0, (4, 3)), zorder=1)
    ax.annotate(text, xy=(0.995, y), xycoords=("axes fraction", "data"),
                ha="right", va="bottom", fontsize=8, color=INK_FAINT)


def mark_centre(ax, xs, pts, centre_label):
    for i, pt in enumerate(pts):
        if pt["label"] == centre_label:
            ax.axvline(xs[i], color=INK_FAINT, linewidth=1.0, linestyle=(0, (1, 3)), zorder=1)
            return


def flag_same_work(ax, xs, pts, ys):
    """Ring the points whose two halves did not do the same work, and say so once."""
    bad = [(x, y) for x, y, pt in zip(xs, ys, pts) if y is not None and not same_work(pt)]
    if not bad:
        return False
    ax.plot([x for x, _ in bad], [y for _, y in bad], linestyle="none", marker="o",
            markersize=MARK_SZ + 7, markerfacecolor="none", markeredgecolor=CRITICAL,
            markeredgewidth=1.6, zorder=4)
    return True


def label_extremes(ax, xs, ys, color):
    """Selective direct labels: the best and worst value of the series, not every point.

    Both labels sit below their marker and the axes carry extra margin, so neither can land on
    the tick labels or on the same-work ring."""
    vals = [(x, y) for x, y in zip(xs, ys) if y is not None]
    if not vals:
        return
    for x, y in {min(vals, key=lambda v: v[1]), max(vals, key=lambda v: v[1])}:
        ax.annotate(f"{y:+.1f}%", xy=(x, y), xytext=(0, -19), textcoords="offset points",
                    ha="center", fontsize=8, color=color)
    ax.margins(y=0.22)


KNOB_TITLE = {
    "n": "matrix size  -n",
    "b": "block size  -b",
    "p": "threads  -p",
}


def draw_sweep(points, centre, out_png, source):
    knobs = [(k, axis_slice(points, k, centre)) for k in ("n", "b", "p")]
    knobs = [(k, s) for k, s in knobs if s]
    if not knobs:
        return None

    rows = 4
    fig, axes = plt.subplots(rows, len(knobs), squeeze=False,
                             figsize=(5.2 * len(knobs), 3.3 * rows))
    fig.patch.set_facecolor(SURFACE)
    flagged_anywhere = False

    for col, (knob, pts) in enumerate(knobs):
        xs = list(range(len(pts)))
        ticks = [str(pt["_x"]) for pt in pts]
        sub = KNOB_TITLE[knob]

        # row 0 - the headline: what the switch did to traffic and to time.
        ax = axes[0][col]
        dm = [delta(pt, "memAcc") for pt in pts]
        dc = [delta(pt, "L2_Cycles") for pt in pts]
        series(ax, xs, dm, S1, "memory accesses")
        series(ax, xs, dc, S2, "L2 cycles")
        ref_line(ax, 0, "no change")
        flagged_anywhere |= flag_same_work(ax, xs, pts, dm)
        label_extremes(ax, xs, dm, S1)
        style(ax, f"SBC effect vs {sub}", "migrate=on vs off  (%)")
        legend(ax)

        # row 1 - is parking paying for itself?
        ax = axes[1][col]
        series(ax, xs, [pt["on"]["hitsPerPark"] for pt in pts], S1)
        ref_line(ax, 1.0, "break-even")
        style(ax, f"Hits per park vs {sub}", "secHits / migrations")

        # row 2 - how hard the SBC tried, and how often it was refused.
        ax = axes[2][col]
        series(ax, xs, [pt["on"]["attempted"] for pt in pts], S1, "attempted")
        series(ax, xs, [pt["on"]["aborted"] for pt in pts], S2, "aborted")
        style(ax, f"Migration attempts vs {sub}", "events in the window")
        legend(ax)

        # row 3 - the mechanism: did the hit rate actually move?
        ax = axes[3][col]
        series(ax, xs, [pt["off"]["hitRate"] for pt in pts], S1, "migrate=off")
        series(ax, xs, [pt["on"]["hitRate"] for pt in pts], S2, "migrate=on")
        style(ax, f"L2 hit rate vs {sub}", "primary + secondary  (%)")
        legend(ax)

        for row in range(rows):
            axes[row][col].set_xticks(xs)
            axes[row][col].set_xticklabels(ticks)
            axes[row][col].set_xlabel(sub, fontsize=9, color=INK_SOFT)
            mark_centre(axes[row][col], xs, pts, centre["label"])

    note = ("dotted vertical = the centre point  ·  one knob moves per point")
    if flagged_anywhere:
        note += (f"  ·  red ring = accessA differs by more than {SAME_WORK_TOL:.0f}% between the "
                 "phases, so that point's deltas are not an SBC effect")
    fig.suptitle(f"SBC migration sweep - {os.path.basename(source)}",
                 fontsize=13, color=INK, x=0.012, ha="left", y=0.995)
    fig.text(0.012, 0.967, note, fontsize=9, color=INK_SOFT, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.958))
    fig.savefig(out_png, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    return out_png


def draw_policy(points, centre, out_png):
    pts = policy_slice(points, centre)
    if not pts:
        return None
    pts.sort(key=lambda q: q["policy"])
    names = [pt["policy"] for pt in pts]
    xs = list(range(len(pts)))

    fig, axes = plt.subplots(1, 3, figsize=(12, 3.6))
    fig.patch.set_facecolor(SURFACE)
    panels = [
        ("memory accesses", [delta(pt, "memAcc") for pt in pts], "migrate=on vs off  (%)", S1, 0.0),
        ("L2 cycles",       [delta(pt, "L2_Cycles") for pt in pts], "migrate=on vs off  (%)", S2, 0.0),
        ("hits per park",   [pt["on"]["hitsPerPark"] for pt in pts], "secHits / migrations", S1, 1.0),
    ]
    for ax, (title, vals, ylab, color, ref) in zip(axes, panels):
        bars = ax.bar(xs, [v if v is not None else 0 for v in vals], width=0.45, color=color,
                      edgecolor=SURFACE, linewidth=1.5, zorder=3)
        for rect, v in zip(bars, vals):
            if v is None:
                continue
            ax.annotate(f"{v:+.2f}" if ref == 0.0 else f"{v:.2f}",
                        xy=(rect.get_x() + rect.get_width() / 2, v),
                        xytext=(0, 5 if v >= 0 else -14), textcoords="offset points",
                        ha="center", fontsize=9, color=INK_SOFT)
        ref_line(ax, ref, "no change" if ref == 0.0 else "break-even")
        ax.margins(y=0.20)          # room for the value labels, so they clear the tick labels
        style(ax, f"{title} by victim policy", ylab)
        ax.set_xticks(xs)
        ax.set_xticklabels(names)
        ax.set_xlabel(f"L2_Replacement  (n={centre['n']} b={centre['b']} p={centre['p']})",
                      fontsize=9, color=INK_SOFT)
    fig.suptitle("SBC migration by victim policy, at the centre point",
                 fontsize=13, color=INK, x=0.012, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.savefig(out_png, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    return out_png


def draw_per_point(points, out_png, source):
    """Fallback for a plan with no numeric knob (-plan parsec): one bar per point."""
    pts = list(points.values())
    if not pts:
        return None
    ys = list(range(len(pts)))[::-1]
    fig, axes = plt.subplots(1, 2, figsize=(12, 1.0 + 0.42 * len(pts)), sharey=True)
    fig.patch.set_facecolor(SURFACE)
    for ax, (title, key, color) in zip(axes, [("Memory accesses", "memAcc", S1),
                                              ("L2 cycles", "L2_Cycles", S2)]):
        vals = [delta(pt, key) for pt in pts]
        ax.barh(ys, [v if v is not None else 0 for v in vals], height=0.5, color=color,
                edgecolor=SURFACE, linewidth=1.5, zorder=3)
        for y, v, pt in zip(ys, vals, pts):
            if v is None:
                continue
            flag = "" if same_work(pt) else "  !same work"
            ax.annotate(f"{v:+.2f}%{flag}", xy=(v, y), xytext=(6 if v >= 0 else -6, 0),
                        textcoords="offset points", va="center",
                        ha="left" if v >= 0 else "right", fontsize=9,
                        color=INK_SOFT if not flag else CRITICAL)
        ax.axvline(0, color=INK_FAINT, linewidth=1.0, zorder=1)
        ax.margins(x=0.22)          # room for the value labels beside the longest bars
        style(ax, f"{title}, migrate=on vs off", "")
        ax.grid(axis="y", linewidth=0)
        ax.grid(axis="x", color="#e6e5e1", linewidth=0.8)
        ax.set_xlabel("percent", fontsize=9, color=INK_SOFT)
    axes[0].set_yticks(ys)
    axes[0].set_yticklabels([pt["label"] for pt in pts], fontsize=9)
    fig.suptitle(f"SBC migration A/B - {os.path.basename(source)}",
                 fontsize=13, color=INK, x=0.012, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.savefig(out_png, dpi=150, facecolor=SURFACE)
    plt.close(fig)
    return out_png


# ── the table view ────────────────────────────────────────────────────────────────────────
SUMMARY_COLS = [
    ("point", lambda pt: pt["label"]),
    ("axis", lambda pt: pt["axis"]),
    ("runs", lambda pt: f"{pt.get('off_runs', 0)}/{pt.get('on_runs', 0)}"),
    ("memAcc.off", lambda pt: f"{pt['off']['memAcc']:.0f}"),
    ("memAcc.on", lambda pt: f"{pt['on']['memAcc']:.0f}"),
    ("memAcc.d%", lambda pt: fmt(delta(pt, "memAcc"), "%+.2f")),
    ("cyc.d%", lambda pt: fmt(delta(pt, "L2_Cycles"), "%+.2f")),
    ("accessA.d%", lambda pt: fmt(delta(pt, "accessA"), "%+.2f")),
    ("hit%.off", lambda pt: fmt(pt["off"]["hitRate"], "%.2f")),
    ("hit%.on", lambda pt: fmt(pt["on"]["hitRate"], "%.2f")),
    ("migrations", lambda pt: f"{pt['on']['migrations']:.0f}"),
    ("hits/park", lambda pt: fmt(pt["on"]["hitsPerPark"], "%.2f")),
    ("abort%", lambda pt: fmt(pt["on"]["abortRate"], "%.1f")),
    ("parked", lambda pt: f"{pt['on']['parked']:.0f}"),
    ("same_work", lambda pt: "ok" if same_work(pt) else "FAILED"),
]


def fmt(v, spec):
    return "-" if v is None else spec % v


def write_summary(points, path):
    rows = [[name for name, _ in SUMMARY_COLS]]
    rows += [[fn(pt) for _, fn in SUMMARY_COLS] for pt in points.values()]
    with open(path, "w", newline="") as fh:
        csv.writer(fh).writerows(rows)
    width = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    for i, row in enumerate(rows):
        print("  " + "  ".join(c.ljust(w) for c, w in zip(row, width)))
        if i == 0:
            print("  " + "  ".join("-" * w for w in width))
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", help="a *_runs_*.csv written by run_parsec_session.exp")
    ap.add_argument("-o", "--outdir", default=None, help="where to write (default: beside the csv)")
    args = ap.parse_args()

    points = load(args.csv)
    if not points:
        sys.exit("no point in this csv has a completed run on both sides of the switch")

    stem = os.path.splitext(os.path.basename(args.csv))[0]
    outdir = args.outdir or os.path.dirname(os.path.abspath(args.csv))
    os.makedirs(outdir, exist_ok=True)
    out = lambda suffix: os.path.join(outdir, f"{stem}_{suffix}")

    print(f"\n{len(points)} point(s) with both phases, from {args.csv}\n")
    written = [write_summary(points, out("summary.csv"))]

    centre = centre_of(points)
    sweep = draw_sweep(points, centre, out("sweep.png"), args.csv)
    if sweep:
        written.append(sweep)
        pol = draw_policy(points, centre, out("policy.png"))
        if pol:
            written.append(pol)
    else:
        written.append(draw_per_point(points, out("points.png"), args.csv))

    good = [pt for pt in points.values() if same_work(pt) and delta(pt, "memAcc") is not None]
    if good:
        best = min(good, key=lambda pt: delta(pt, "memAcc"))
        print(f"\n  best memory-traffic point that passes the same-work check: {best['label']}"
              f"  ({delta(best, 'memAcc'):+.2f}% memAcc, "
              f"{fmt(delta(best, 'L2_Cycles'), '%+.2f')}% L2 cycles, "
              f"hits/park {fmt(best['on']['hitsPerPark'], '%.2f')})")
    bad = [pt["label"] for pt in points.values() if not same_work(pt)]
    if bad:
        print(f"  !! same-work check failed for: {', '.join(bad)} - their deltas are not an "
              "SBC effect")

    print("\n  wrote:")
    for w in written:
        if w:
            print(f"    {w}")
    print()


if __name__ == "__main__":
    main()
