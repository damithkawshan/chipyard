# ssbc session library

The serial / zmodem / staging layer shared by the `run_*_session.exp` scripts.

| File | Provides | Needs from the caller |
|---|---|---|
| `config.exp` | `DEVICE` `BAUD` `SEND_CMD` `RECV_CMD` `LOGIN` `PASSWORD` `PROMPT` `BOOT_TMO` `CY` `SCRIPTS` `SW_DIR` `STAGED` `LOGDIR` `send_slow` | — |
| `board.exp` | `board_cmd` `board_run` `board_probe` `bail` `drain` `dget` | `PROMPT`, `LOGPATH`, optionally `CSVPATH` |
| `transfer.exp` | `zmodem_send` | `PROMPT`, `pushed_bytes`; `board.exp` |
| `staging.exp` | `board_matches` `stage_file` `stage_one` | `HAVE_MD5` `PUSH` `BOARD_DIR` `STAGED`; `board.exp`, `transfer.exp` |
| `counters.exp` | `num` `parse_counters` | — |

Source them before the script's own configuration:

```tcl
set LIB [file join [file dirname [file normalize [info script]]] lib]
source [file join $LIB config.exp]
source [file join $LIB board.exp]
source [file join $LIB transfer.exp]
source [file join $LIB staging.exp]
source [file join $LIB counters.exp]
```

## Why this exists

Before extraction the five large session scripts carried forked copies of this layer at
different vintages, and the laggards still held bugs fixed only in `run_pair_session.exp` and
`run_parsec_session.exp`:

- **`bail`** — `run_board_session` and `run_benchmarks_session` had the 8-line version with an
  unbounded `expect eof`: the hang that cost the 2026-10-02 dual-core session. The version here
  gives picocom 15 s and then `pkill`s it so the port is released.
- **`zmodem_send`** — `run_benchmarks_session` had no `ESC[6n` reply, no retry, and no 90 s
  fail-fast, so it stalled at picocom's file prompt and burned 900 s to learn `sz` never started.
- **`TERM=dumb`** — missing from `run_board_session`, `run_benchmarks_session` and
  `reboot_and_handover`. That is the *primary* linenoise fix; the `ESC[6n` reply in
  `transfer.exp` is only the backstop.

Canonical source for every file here is `run_pair_session.exp` / `run_parsec_session.exp` as of
2026-10-05, where the two agreed byte-for-byte on all 12 procs.

## Deliberately not shared

- `pct`, `memacc` — pair and parsec hold genuinely different versions. Converging them is a
  behaviour change, not a move.
- `stage_sbc_read` — identical code in both, but the two carry different comments worth keeping.
- the connect/boot block (program FPGA, spawn picocom, find the prompt, log in) — identical in
  substance across all five, but `spawn` inside a proc sets a proc-local `spawn_id`, so wrapping
  it needs an explicit `global spawn_id` and a live board to verify. Deferred.

## Changing anything here

Every timeout and every `expect` branch below is calibrated against a dated hardware failure;
the comments name them. Read the comment before changing the line. The static checks are:

1. `-list` on both scripts, diffed against recorded output (exercises CLI, registry, plan; never
   opens the port).
2. proc-body hashes, comments and whitespace stripped, compared before and after.

Neither covers the board-touching paths. Those need a live run - `run_pair_session.exp -pair
lu,blackscholes` is the documented harness self-test.
