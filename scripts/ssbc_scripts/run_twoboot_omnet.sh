#!/bin/bash
# run_twoboot_omnet.sh - Two-boot omnetpp evaluation:
#   Run 1: Program 64K SBCPLRU bitstream -> Migration ON  -> Run omnet
#   Run 2: Reprogram 64K SBCPLRU bitstream -> Migration OFF -> Run omnet
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPTS_DIR"

echo "=================================================================="
echo "===== STARTING TWO-BOOT EVALUATION"
echo "===== Run 1: Program FPGA -> Migration ON  -> Run omnet"
echo "===== Run 2: Reprogram FPGA -> Migration OFF -> Run omnet"
echo "=================================================================="
date

echo ""
echo "##################################################################"
echo "##### [RUN 1/2] REPROGRAMMING FPGA -> MIGRATION OFF (PLAIN L2 BASELINE)"
echo "##################################################################"
./run_board_session.exp -migrate off -policy plru "$@"

echo ""
echo "##################################################################"
echo "##### [RUN 2/2] MIGRATION ON (SBC ACTIVE)"
echo "##################################################################"
./run_board_session.exp -migrate on -policy plru "$@"


echo ""
echo "=================================================================="
echo "===== BOTH RUNS COMPLETED SUCCESSFULLY"
echo "=================================================================="
date
