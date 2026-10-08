# LU pair on one core: results

**Status:** {{status}} · updated {{updated}}
Method and predictions: [PLAN.md](PLAN.md) · raw tables: [results/table.md](results/table.md) · numbers: [results/numbers.json](results/numbers.json)

## Setup

- Pair: `lu_ncb` n=512, block 32 + block 128, started together, one core, shared 256 KB L2
- Baseline: the two programs run alone (clean sweep windows)
- Memory accesses = DRAM reads + writes from the L2
- Interference = pair − baseline
- Every window: fresh FPGA reprogram + boot

## Windows

{{windows_table}}

## Summary ({{mean_note}})

| memory accesses (M) | SBC off | SBC on | change |
|---|--:|--:|--:|
| Baseline (alone) | {{base_off}} | {{base_on}} | {{base_chg}} ({{base_chg_pct}}) |
| Pair (together) | {{pair_off}} | {{pair_on}} | {{pair_chg}} ({{pair_chg_pct}}) |
| **Interference** | **{{intf_off}}** | **{{intf_on}}** | **{{intf_chg}} ({{intf_chg_pct}})** |
| Interference, % of baseline | {{intf_off_pct}} | {{intf_on_pct}} | {{intf_pp}} |

{{per_run_section}}

## Verdict

- Recovered: **{{rec_M}} M = {{share}}%** of the interference
- Band fixed before run 1: **{{band}}** = {{band_word}}
- Noise: {{share_lo}}–{{share_hi}}% ({{settled}})
- Noise per window: {{sigma_solo}} alone (LU n=768 repeat), {{sigma_pair}} pair ({{sigma_pair_src}})
- Board run time, SBC off to on: {{rt38}}

## Run time projection (model)

{{runtime_table}}

## Caveats

- L2 counters cover both programs: no per-program attribution
- "Recovered" assumes SBC's baseline gain carries over to the pair
- Interference may include OS effects: the pair makes {{access_extra}}% more L2 accesses than the two alone

Nothing is committed.
