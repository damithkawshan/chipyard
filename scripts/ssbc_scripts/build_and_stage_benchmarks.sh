#!/bin/bash
#
# build_and_stage_benchmarks.sh - Build bodytrack, barnes, and lu for RISC-V 64
# and stage their binaries + input files into the staged/ directory.
#
# Prerequisites:
#   source /home/damith/Research/repos/chipyard_performance_eval/chipyard/env.sh
#
# Don't use set -e: we want to continue building other benchmarks even if one fails

CY="/home/damith/Research/repos/chipyard_performance_eval/chipyard"
PARSECDIR="$CY/software/parsec-benchmark"
STAGED="$PARSECDIR/staged"

# Source env if not done
if [ -z "$RISCV" ]; then
    echo "Sourcing chipyard env.sh ..."
    source "$CY/env.sh"
fi

export PARSECDIR
mkdir -p "$STAGED"

echo "============================================"
echo " Building PARSEC/SPLASH-2 for RISC-V 64    "
echo " Benchmarks: bodytrack, barnes, lu_ncb      "
echo "============================================"

cd "$PARSECDIR"

# ── BODYTRACK ──
echo ""
echo "=== Building bodytrack ==="
./bin/parsecmgmt -a build -p bodytrack -c gcc-riscv64 2>&1 | tail -20
BT_BIN="$PARSECDIR/pkgs/apps/bodytrack/obj/amd64-linux.gcc-riscv64/bodytrack"
if [ -f "$BT_BIN" ]; then
    cp "$BT_BIN" "$STAGED/bodytrack"
    echo ">>> bodytrack staged OK"
else
    # bodytrack may produce 'TrackingBenchmark' as the binary name
    BT_ALT=$(find "$PARSECDIR/pkgs/apps/bodytrack/obj/amd64-linux.gcc-riscv64" -maxdepth 2 -type f -executable -name "bodytrack" -o -name "TrackingBenchmark" 2>/dev/null | head -1)
    if [ -n "$BT_ALT" ]; then
        cp "$BT_ALT" "$STAGED/bodytrack"
        echo ">>> bodytrack staged from $BT_ALT"
    else
        echo "!!! bodytrack binary not found after build"
    fi
fi

# Stage bodytrack input files (simdev)
echo "--- Staging bodytrack input files (simdev) ..."
BT_INPUT="$PARSECDIR/pkgs/apps/bodytrack/inputs/input_simdev.tar"
if [ -f "$BT_INPUT" ]; then
    mkdir -p "$STAGED/bodytrack_inputs"
    cd "$STAGED/bodytrack_inputs"
    tar xf "$BT_INPUT"
    # The tar usually contains a sequenceB_1 directory with .bmp images
    if [ -d sequenceB_1 ]; then
        cp -r sequenceB_1 "$STAGED/"
        echo ">>> bodytrack simdev input (sequenceB_1) staged"
    else
        echo "!!! sequenceB_1 not found in input archive"
        ls -la
    fi
    cd "$PARSECDIR"
fi

# ── BARNES (SPLASH-2) ──
echo ""
echo "=== Building barnes (SPLASH-2) ==="
./bin/parsecmgmt -a build -p splash2.barnes -c gcc-riscv64 2>&1 | tail -20
BA_BIN=$(find "$PARSECDIR/ext/splash2/apps/barnes/obj/amd64-linux.gcc-riscv64" -maxdepth 1 -type f -executable 2>/dev/null | head -1)
if [ -n "$BA_BIN" ]; then
    cp "$BA_BIN" "$STAGED/barnes"
    echo ">>> barnes staged OK"
else
    echo "!!! barnes binary not found after build"
fi

# Barnes needs an input file - create a small test input
# SPLASH-2 barnes reads params from stdin
# Format: <nbodies>
cat > "$STAGED/barnes_input" << 'BEOF'
1024
123
0.025
0.5
0.0
1
0
BEOF
echo ">>> barnes input file staged"

# ── LU (SPLASH-2) ──
echo ""
echo "=== Building lu_ncb (SPLASH-2) ==="
./bin/parsecmgmt -a build -p splash2.lu_ncb -c gcc-riscv64 2>&1 | tail -20
LU_BIN=$(find "$PARSECDIR/ext/splash2/kernels/lu_ncb/obj/amd64-linux.gcc-riscv64" -maxdepth 1 -type f -executable 2>/dev/null | head -1)
if [ -n "$LU_BIN" ]; then
    cp "$LU_BIN" "$STAGED/lu"
    echo ">>> lu staged OK"
else
    echo "!!! lu binary not found after build"
fi

echo ""
echo "============================================"
echo " Staged files:"
ls -la "$STAGED/"
echo "============================================"
echo "Done. Run the benchmark session with:"
echo "  expect scripts/ssbc_scripts/run_benchmarks_session.exp"
