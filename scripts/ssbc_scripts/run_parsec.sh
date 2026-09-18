#!/bin/sh
# Usage: run_parsec.sh <benchmark> <nthreads>
# Available: blackscholes fluidanimate freqmine swaptions streamcluster

# BIN=/research/repos/chipyard/software/damith_benchmarks/parsec-benchmark/pkgs/apps
BIN=/test_dir/test_dir

# /research/repos/chipyard/software/damith_benchmarks/parsec-benchmark/pkgs/apps/blackscholes/tmp

if [ $# -lt 2 ]; then
    echo "Usage: $0 <benchmark> <nthreads>"
    exit 1
fi

BENCH=$1
NTHREADS=$2

case $BENCH in
    blackscholes)
        cd $DATA/blackscholes
        $BIN/blackscholes/obj/amd64-linux.gcc-riscv64/blackscholes $NTHREADS $BIN/blackscholes/tmp/in_16.txt $BIN/blackscholes/tmp/prices.txt
        ;;
    fluidanimate)
        cd $DATA/fluidanimate
        $BIN/fluidanimate/obj/amd64-linux.gcc-riscv64/fluidanimate $NTHREADS 3 $BIN/fluidanimate/tmp/in_15K.fluid $BIN/fluidanimate/tmp/out.fluid
        ;;
    freqmine)
        cd $DATA/freqmine
        OMP_NUM_THREADS=$NTHREADS $BIN/freqmine/obj/amd64-linux.gcc-riscv64/freqmine $BIN/freqmine/tmp/T10I4D100K_1k.dat 3
        ;;
    swaptions)
        $BIN/swaptions/obj/amd64-linux.gcc-riscv64/swaptions -ns 3 -sm 50 -nt $NTHREADS
        ;;
    streamcluster)
        $BIN/streamcluster/obj/amd64-linux.gcc-riscv64/streamcluster 3 10 3 16 16 10 none $BIN/streamcluster/tmp/streamcluster_out.txt $NTHREADS
        ;;
    *)
        echo "Unknown benchmark: $BENCH"
        echo "Available: blackscholes fluidanimate freqmine swaptions streamcluster"
        exit 1
        ;;
esac
