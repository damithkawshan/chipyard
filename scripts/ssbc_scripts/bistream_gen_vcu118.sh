#!/bin/bash
# bistream_gen_vcu118.sh — build VCU118 bitstream(s).
#
# Usage:
#   ./bistream_gen_vcu118.sh              # both, NoSBC first (the measurement pair, 256KB L2)
#   ./bistream_gen_vcu118.sh sbc          # SBC only (256KB L2)
#   ./bistream_gen_vcu118.sh nosbc        # SBC-off baseline only (256KB L2)
#   ./bistream_gen_vcu118.sh both_64l2    # both, NoSBC first (64KB L2 pair)
#   ./bistream_gen_vcu118.sh sbc_64l2     # SBC only (64KB L2)
#   ./bistream_gen_vcu118.sh nosbc_64l2   # SBC-off baseline only (64KB L2)
#   ./bistream_gen_vcu118.sh sbc_64l2_plru # SBC + PLRU (64KB L2, task 008; policy chosen at run time)
#   ./bistream_gen_vcu118.sh sbc_64l2_plru_dual # same, 2 cores
#   ./bistream_gen_vcu118.sh both_128l2   # both, NoSBC first (128KB L2 pair)
#   ./bistream_gen_vcu118.sh sbc_128l2    # SBC only (128KB L2)
#   ./bistream_gen_vcu118.sh nosbc_128l2  # SBC-off baseline only (128KB L2)
#   ./bistream_gen_vcu118.sh <ConfigName> # any explicit config
#
# Why a pair: enableSetBalancing is COMPILE-TIME. There is no runtime disable, so the SBC-off
# baseline needs its own bitstream. Without both, no number can be called a gain or a loss.
#
# Every build first deletes that config's generated-src dir (RTL, Vivado obj/, old .bit). Make is
# timestamp-driven, so a leftover .fir/.sv or synth checkpoint can be silently reused and the new
# bitstream would not reflect the current RTL. Only that one config's dir goes: `make clean` would
# wipe ALL of generated-src, including other configs' bitstreams. Archive a .bit you want to keep
# BEFORE running this.
#
# After both finish, compare area + timing with the sibling script:
#   ./compare_reports.sh "$NOSBC" "$SBC"
#
# NOTE: do not add `set -u`. env.sh sources a conda activate.d script that references $RISCV
# before defining it, which `set -u` turns into a fatal "unbound variable" error.

REPO_DIR=/home/damith/Research/repos/chipyard_performance_eval/chipyard
LOG_DIR="$REPO_DIR/fpga/build-logs"

# --- the measurement pair -------------------------------------------------------------------
NOSBC=FPGASingleRocketVCU118L18K256K16WL2ConfigNoSbc         # SBC-off baseline twin
SBC=FPGASingleRocketVCU118L18K256K16WL2ConfigSBCResetEnabled # SBC + SBC_StatsReset (0x3B8)

NOSBC_64L2=FPGASingleRocketVCU118L18K64K16WL2ConfigNoSbc
SBC_64L2=FPGASingleRocketVCU118L18K64K16WL2ConfigSBC
SBC_64L2_PLRU=FPGASingleRocketVCU118L18K64K16WL2ConfigSBCPLRU
SBC_64L2_PLRU_DUAL=FPGADualRocketVCU118L18K64K16WL2ConfigSBCPLRU

NOSBC_128L2=FPGASingleRocketVCU118L18K128K16WL2ConfigNoSbc
SBC_128L2=FPGASingleRocketVCU118L18K128K16WL2ConfigSBC

SINGLE_1M_8W=FPGASingleRocketVCU118L18K1024K8WL2ConfigSBCPLRU
DUAL_1M_8W=FPGADualRocketVCU118L18K1024K8WL2ConfigSBCPLRU

# --- other configs previously built (kept as a record; pass any of these as an argument) -----
# SingleRocketVCU118L18K256K16WL2ConfigTLCounter
# QuadRocketVCU118ConfigSatTLCounter256KL2Config
# FPGASingleRocketVCU118L18K256K16WL2ConfigSBCPhase2Finish   # stale: shadow+debug ON
# FPGASingleRocketVCU118L18K256K16WL2ConfigSBC               # SBC without SBC_StatsReset (archived)

source "$REPO_DIR/env.sh"
mkdir -p "$LOG_DIR"
cd "$REPO_DIR/fpga" || exit 1

STAMP=$(date +%Y%m%d-%H%M%S)

build_one () {
  local cfg="$1"
  local log="$LOG_DIR/${cfg}-${STAMP}.log"
  local gen="$REPO_DIR/fpga/generated-src/chipyard.fpga.vcu118.VCU118FPGATestHarness.${cfg}"
  echo "=============================================================="
  echo "[$(date '+%F %T')] START  $cfg"
  echo "[$(date '+%F %T')] log -> $log"
  echo "=============================================================="
  if [ -d "$gen" ]; then
    echo "[$(date '+%F %T')] CLEAN  $gen"
    rm -rf "$gen"
  fi
  if make -j20 SUB_PROJECT=vcu118 CONFIG="$cfg" bitstream > "$log" 2>&1; then
    local bit="$gen/obj/VCU118FPGATestHarness.bit"
    if [ -f "$bit" ]; then
      echo "[$(date '+%F %T')] OK     $cfg"
      echo "                     -> $bit"
      return 0
    fi
    echo "[$(date '+%F %T')] FAIL   $cfg  (make succeeded but produced no .bit)"
    return 1
  fi
  echo "[$(date '+%F %T')] FAIL   $cfg  (see $log)"
  echo "---- last 30 lines ----"
  tail -30 "$log"
  return 1
}

rc=0
case "${1:-both}" in
  both)       build_one "$NOSBC" || rc=1     # baseline first: the one we most need if time runs short
              build_one "$SBC"   || rc=1 ;;
  nosbc)      build_one "$NOSBC" || rc=1 ;;
  sbc)        build_one "$SBC"   || rc=1 ;;
  nosbc_64l2) build_one "$NOSBC_64L2" || rc=1 ;;
  sbc_64l2)   build_one "$SBC_64L2"   || rc=1 ;;
  sbc_64l2_plru) build_one "$SBC_64L2_PLRU" || rc=1 ;;
  sbc_64l2_plru_dual) build_one "$SBC_64L2_PLRU_DUAL" || rc=1 ;;
  both_64l2)  build_one "$NOSBC_64L2" || rc=1
              build_one "$SBC_64L2"   || rc=1 ;;
  nosbc_128l2) build_one "$NOSBC_128L2" || rc=1 ;;
  sbc_128l2)   build_one "$SBC_128L2"   || rc=1 ;;
  both_128l2)  build_one "$NOSBC_128L2" || rc=1
               build_one "$SBC_128L2"   || rc=1 ;;
  single_1m_8w) build_one "$SINGLE_1M_8W" || rc=1 ;;
  dual_1m_8w)   build_one "$DUAL_1M_8W"   || rc=1 ;;
  FPGA*)       build_one "$1"          || rc=1 ;;  # explicit config with FPGA prefix
  *)           build_one "FPGA$1"      || rc=1 ;;  # auto-prepend FPGA prefix if omitted
esac

echo "=============================================================="
echo "[$(date '+%F %T')] DONE (exit $rc)"
if [ $rc -eq 0 ]; then
  case "${1:-both}" in
    both)       echo "next: ./compare_reports.sh $NOSBC $SBC" ;;
    both_64l2)  echo "next: ./compare_reports.sh $NOSBC_64L2 $SBC_64L2" ;;
    both_128l2) echo "next: ./compare_reports.sh $NOSBC_128L2 $SBC_128L2" ;;
  esac
fi
exit $rc
