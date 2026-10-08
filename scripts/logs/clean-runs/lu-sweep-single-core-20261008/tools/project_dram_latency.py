#!/usr/bin/env python3
"""What the LU sweep's OFF -> ON cycle change would be if a DRAM read cost more cycles than it does on this board.

usage: project_dram_latency.py <sweep_dir> [board_cycles_per_read]

A FIRST-ORDER MODEL, NOT A MEASUREMENT. Inputs are the measured VALID stages (results/results.csv and
on/<label>/stage_result.json); writes results/dram_latency_projection.txt.

Why: on the VCU118 the core, L2 and every bus run at 50 MHz while the DDR4 controller runs at 800 MHz
(DDR4-1600), so a DRAM read costs few core cycles. The L1 D-cache is blocking (WithNBigCores: nMSHRs = 0), so every
miss stalls the core and none overlap.

Board cost of one DRAM read, measured two ways (default 38 L2 cycles beyond an L2 hit):
  - calib envelope sweep 2026-09-25 (64 KB 16-way, same 50 MHz platform and memory path), 80 A/B points:
    least-squares cycles change = 38.0 x reads change, R^2 = 0.990
  - LU n=768 b=128 OFF, two fresh boots, same work (accessA +0.01%): +140,193 reads, +135,570 writes,
    +5,243,900 cycles; 38 x the reads predicts 5.33 M, so the extra write-backs cost about nothing

Model: run time T = C + R x L (R = DRAM reads, L = cycles per read). Everything else (core, L1, L2 hits, second
searches, migration copies) keeps its board cycle count, as the same RTL would at a higher clock. Then
  T_real = T_board + R_off x (LR - LF),  change_real = change_board + (R_on - R_off) x (LR - LF).
Write-backs are left off the critical path (consistent with the n=768 pair). Assumes every read miss stalls the core
and the L2 is the last-level cache; an out-of-order core, a prefetcher or an L3 would make the gain smaller.
"""
import csv, json, sys

sw = sys.argv[1]
LF = float(sys.argv[2]) if len(sys.argv) > 2 else 38.0
LRS = (100, 200, 300)            # cycles per DRAM read in a 1 / 2 / 3 GHz chip with ~100 ns to DRAM

rows = sorted(csv.DictReader(open(f"{sw}/results/results.csv")), key=lambda r: (int(r["n"]), int(r["b"])))
out = ["First-order model, not a measurement (see the docstring of tools/project_dram_latency.py).",
       "Board cost of one DRAM read: LF = %.0f L2 cycles beyond an L2 hit." % LF, "",
       "1. Board cycles, OFF -> ON, split into the reads saved (x LF) and the rest (SBC's on-chip cost + noise)",
       "  n     b    reads saved x LF   rest     measured   secondSearch (ON)   rest / secondSearch"]
for r in rows:
    on = json.load(open(f"{sw}/on/{r['label']}/stage_result.json"))["counters"]
    T = float(r["L2cyc_off"]); d = float(r["L2cyc_on"]) - T
    dR = float(r["memReads_on"]) - float(r["memReads_off"])
    rest = d - dR * LF
    out.append("  %-5s %-4s %+7.2f%%      %+7.2f%%   %+7.2f%%   %14d   %10.1f cycles" % (
        r["n"], r["b"], 100 * dR * LF / T, 100 * rest / T, 100 * d / T, on["secondSearch"], rest / on["secondSearch"]))
out += ["", "2. Projected run-time change OFF -> ON if a DRAM read cost LR cycles",
        "  n     b    reads Δ   board (LF)  " + "  ".join("LR=%d" % x for x in LRS) + "   DRAM share of OFF time at LR=200"]
for r in rows:
    T = float(r["L2cyc_off"]); d = float(r["L2cyc_on"]) - T
    R = float(r["memReads_off"]); dR = float(r["memReads_on"]) - R
    proj = ["%+6.2f%%" % (100 * (d + dR * (lr - LF)) / (T + R * (lr - LF))) for lr in LRS]
    share = R * 200 / (T + R * (200 - LF))
    out.append("  %-5s %-4s %+6.2f%%   %+6.2f%%    %s   %4.0f%%" % (
        r["n"], r["b"], 100 * dR / R, 100 * d / T, "  ".join(proj), 100 * share))
open(f"{sw}/results/dram_latency_projection.txt", "w").write("\n".join(out) + "\n")
print("\n".join(out))
