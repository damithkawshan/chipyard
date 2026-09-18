#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" # chipyard root

# Test application (override with: ./ssbc_testapp.sh nettle_aes)
APP_NAME="${1:-matmult_float}"

TEST_APP_LOC=$1

# TEST_APP_LOC="${TEST_APP_LOC:-$REPO_ROOT/generators/rocket-chip-inclusive-cache/sw/verilator_sim/${APP_NAME}.riscv}"
# TEST_APP_LOC="${TEST_APP_LOC:-$REPO_ROOT/tests/ssbc_tests/build/${APP_NAME}.riscv}"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/generators/rocket-chip-inclusive-cache/results/${APP_NAME}_$(date +%d%b%Y_%H-%M-%S)}"
MAKE_JOBS="${MAKE_JOBS:-20}"
VERILATOR_THREADS="${VERILATOR_THREADS:-18}"
EVAL_SCOPE="${EVAL_SCOPE:-all}"
SUCCESS_PHRASE="${SUCCESS_PHRASE:-}"
SIM_FINISH_MARKER='Verilog $finish'

BASELINE_CONFIG="VerilatorRocket8KL116KL2Config"
SSBC_CONFIG="VerilatorRocket8KL116KL2Config"
BASELINE_LABEL="bl"
SSBC_LABEL="ssbc"

APP_STEM="$(basename "${TEST_APP_LOC%.riscv}")"
APP_SOURCE_C="${TEST_APP_LOC%.riscv}.c"
EXTRACT_SCRIPT="$REPO_ROOT/generators/rocket-chip-inclusive-cache/verification/scripts/extract_set_hitmiss.py"

BASELINE_SIM_DIR="$REPO_ROOT/sims/verilator/output/chipyard.harness.TestHarness.${BASELINE_CONFIG}"
SSBC_SIM_DIR="$REPO_ROOT/sims/verilator/output/chipyard.harness.TestHarness.${SSBC_CONFIG}"
BASELINE_ARCHIVE_DIR="$RESULTS_DIR/chipyard.harness.TestHarness.${BASELINE_CONFIG}"
SSBC_ARCHIVE_DIR="$RESULTS_DIR/chipyard.harness.TestHarness.${SSBC_CONFIG}"
BASELINE_CHISEL_LOG="$REPO_ROOT/sims/verilator/generated-src/chipyard.harness.TestHarness.${BASELINE_CONFIG}/chipyard.harness.TestHarness.${BASELINE_CONFIG}.chisel.log"
SSBC_CHISEL_LOG="$REPO_ROOT/sims/verilator/generated-src/chipyard.harness.TestHarness.${SSBC_CONFIG}/chipyard.harness.TestHarness.${SSBC_CONFIG}.chisel.log"

BASELINE_ARCHIVE_OUT="$BASELINE_ARCHIVE_DIR/${APP_STEM}.out"
SSBC_ARCHIVE_OUT="$SSBC_ARCHIVE_DIR/${APP_STEM}.out"
BASELINE_ARCHIVE_MEM_ACCESS="$BASELINE_ARCHIVE_DIR/mem_accesses_${APP_STEM}.out"
SSBC_ARCHIVE_MEM_ACCESS="$SSBC_ARCHIVE_DIR/mem_accesses_${APP_STEM}.out"
BASELINE_TOP_MEM_ACCESS="$RESULTS_DIR/mem_accesses_${APP_STEM}_${BASELINE_LABEL}.out"
SSBC_TOP_MEM_ACCESS="$RESULTS_DIR/mem_accesses_${APP_STEM}_${SSBC_LABEL}.out"
BASELINE_APP_LOG="$BASELINE_SIM_DIR/${APP_STEM}.log"
SSBC_APP_LOG="$SSBC_SIM_DIR/${APP_STEM}.log"

copy_required_file() {
  local src="$1"
  local dst="$2"
  if [[ ! -f "$src" ]]; then
    echo "error: required file not found: $src" >&2
    exit 1
  fi
  cp -f "$src" "$dst"
}

copy_optional_file() {
  local src="$1"
  local dst="$2"
  if [[ -f "$src" ]]; then
    cp -f "$src" "$dst"
  fi
}

sync_output_dir() {
  local src_dir="$1"
  local dst_dir="$2"
  if [[ ! -d "$src_dir" ]]; then
    echo "error: simulator output directory not found: $src_dir" >&2
    exit 1
  fi
  mkdir -p "$dst_dir"
  # Copy all files except .vcd files to avoid copying large waveform files
  rsync -a --exclude='*.vcd' "$src_dir/" "$dst_dir/"
}

normalize_baseline_mem_access() {
  local src="$1"
  local dst="$2"
  if [[ ! -f "$src" ]]; then
    echo "error: baseline mem_access log not found: $src" >&2
    exit 1
  fi
  sed \
    -e 's/set=/origSet=/g' \
    -e 's/way=/origWay=/g' \
    -e 's/tag=/origTag=/g' \
    "$src" > "$dst"
}

verify_success_phrase() {
  local label="$1"
  local log_path="$2"

  if [[ ! -f "$log_path" ]]; then
    echo "error: $label app log not found: $log_path" >&2
    exit 1
  fi

  local line_count
  line_count="$(wc -l < "$log_path")"
  if (( line_count < 2 )); then
    echo "warning: $label log is too short to verify automatically" >&2
    echo "log: $log_path" >&2
    tail -n 5 "$log_path" >&2 || true
    if [[ ! -t 0 ]]; then
      echo "error: cannot prompt for confirmation in non-interactive mode" >&2
      exit 1
    fi
    read -r -p "Continue anyway? [y/N] " continue_reply
    [[ "$continue_reply" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 1
    return
  fi

  local final_line
  local success_line
  final_line="$(tail -n 1 "$log_path")"
  success_line="$(tail -n 2 "$log_path" | head -n 1)"

  if [[ "$final_line" == *"$SIM_FINISH_MARKER"* && -n "$success_line" ]]; then
    if [[ -n "$SUCCESS_PHRASE" && "$success_line" != "$SUCCESS_PHRASE" ]]; then
      echo "warning: $label completion line did not match SUCCESS_PHRASE" >&2
      echo "log: $log_path" >&2
      echo "expected completion line: $SUCCESS_PHRASE" >&2
      echo "detected completion line: $success_line" >&2
      echo "actual tail:" >&2
      tail -n 5 "$log_path" >&2
      if [[ ! -t 0 ]]; then
        echo "error: cannot prompt for confirmation in non-interactive mode" >&2
        exit 1
      fi
      read -r -p "Continue anyway? [y/N] " continue_reply
      [[ "$continue_reply" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 1
      return
    fi

    echo "$label completion line: $success_line"
    return
  fi

  echo "warning: $label run could not be verified automatically" >&2
  echo "log: $log_path" >&2
  echo "expected the app completion phrase to appear immediately above the final simulator line" >&2
  echo "actual tail:" >&2
  tail -n 5 "$log_path" >&2
  if [[ ! -t 0 ]]; then
    echo "error: cannot prompt for confirmation in non-interactive mode" >&2
    exit 1
  fi
  read -r -p "Continue anyway? [y/N] " continue_reply
  [[ "$continue_reply" =~ ^[Yy]([Ee][Ss])?$ ]] || exit 1
}

run_config() {
  local label="$1"
  local config="$2"
  local run_log="$3"

  pushd "$REPO_ROOT/sims/verilator" >/dev/null
  # Clean previous simulator output for this config to avoid stale files
  local sim_output_dir="$REPO_ROOT/sims/verilator/output/chipyard.harness.TestHarness.${config}"
  if [[ -d "$sim_output_dir" ]]; then
    echo "Cleaning simulator output directory: $sim_output_dir"
    rm -rf "$sim_output_dir"
  fi
  echo "Running $label config ($config) with $TEST_APP_LOC"
  echo "run log: $REPO_ROOT/sims/verilator/$run_log"
  make -j"$MAKE_JOBS" run-binary-debug \
    BINARY="$TEST_APP_LOC" \
    CONFIG="$config" \
    VERILATOR_THREADS="$VERILATOR_THREADS" \
    SIM_FLAGS=+max-cycles=500000000 \
    > "$run_log" 2>&1
  popd >/dev/null
}

run_evaluation() {
  pushd "$RESULTS_DIR" >/dev/null
  MPLBACKEND=Agg python3 "$EXTRACT_SCRIPT" \
    --bl "chipyard.harness.TestHarness.${BASELINE_CONFIG}/${APP_STEM}.out" \
    --ssbc "chipyard.harness.TestHarness.${SSBC_CONFIG}/${APP_STEM}.out" \
    --scope "$EVAL_SCOPE" \
    --markdown-out "result_table.md"
  popd >/dev/null
}

main() {
  echo "----------------------------------------------------------------------------"
  echo " SSBC Comparison Environment: Testing app $APP_NAME"
  echo "----------------------------------------------------------------------------"
  echo "Repo Root: $REPO_ROOT"
  echo "App name: $APP_NAME"
  echo "Test app location: $TEST_APP_LOC"
  echo "Baseline config: $BASELINE_CONFIG"
  echo "SSBC config: $SSBC_CONFIG"
  echo "Make jobs: $MAKE_JOBS"
  echo "Verilator threads: $VERILATOR_THREADS"
  echo " "
  echo "----------------------------------------------------------------------------"


  echo "sourcing environment from: $REPO_ROOT/env.sh"
  if [[ ! -f "$REPO_ROOT/env.sh" ]]; then
    echo "error: environment file not found: $REPO_ROOT/env.sh" >&2
    exit 1
  fi
  # conda activation hooks in env.sh assume unset vars are allowed.
  set +u
  source "$REPO_ROOT/env.sh"
  set -u
  echo "Using results directory: $RESULTS_DIR"

  mkdir -p "$RESULTS_DIR" "$BASELINE_ARCHIVE_DIR" "$SSBC_ARCHIVE_DIR"


  run_config "ssbc" "$SSBC_CONFIG" "$RESULTS_DIR/ssbc_run.log"
  # run_config "baseline" "$BASELINE_CONFIG" "$RESULTS_DIR/baseline_run.log"
  # verify_success_phrase "baseline" "$BASELINE_APP_LOG"
  # verify_success_phrase "ssbc" "$SSBC_APP_LOG"

  # sync_output_dir "$BASELINE_SIM_DIR" "$BASELINE_ARCHIVE_DIR"
  # sync_output_dir "$SSBC_SIM_DIR" "$SSBC_ARCHIVE_DIR"

  # copy_required_file \
  #   "$BASELINE_CHISEL_LOG" \
  #   "$RESULTS_DIR/chipyard.harness.TestHarness.${BASELINE_CONFIG}.chisel.log"
  # copy_required_file \
  #   "$SSBC_CHISEL_LOG" \
  #   "$RESULTS_DIR/chipyard.harness.TestHarness.${SSBC_CONFIG}.chisel.log"
  # # copy_required_file \
  # #   "$REPO_ROOT/sims/verilator/baseline_run.log" \
  # #   "$RESULTS_DIR/buildlog_baseline_run.log"
  # # copy_required_file \
  # #   "$REPO_ROOT/sims/verilator/ssbc_run.log" \
  # #   "$RESULTS_DIR/buildlog_ssbc_run.log"
  # copy_optional_file "$APP_SOURCE_C" "$RESULTS_DIR/$(basename "$APP_SOURCE_C")"

  # if [[ ! -f "$BASELINE_ARCHIVE_OUT" ]]; then
  #   echo "error: archived baseline .out not found: $BASELINE_ARCHIVE_OUT" >&2
  #   exit 1
  # fi
  # if [[ ! -f "$SSBC_ARCHIVE_OUT" ]]; then
  #   echo "error: archived SSBC .out not found: $SSBC_ARCHIVE_OUT" >&2
  #   exit 1
  # fi

  # run_evaluation

  # normalize_baseline_mem_access "$BASELINE_ARCHIVE_MEM_ACCESS" "$BASELINE_TOP_MEM_ACCESS"
  # copy_required_file "$SSBC_ARCHIVE_MEM_ACCESS" "$SSBC_TOP_MEM_ACCESS"

  echo "Archived results in $RESULTS_DIR"
}

main "$@"
