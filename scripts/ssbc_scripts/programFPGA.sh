#!/bin/bash
# Filename: program_fpga.sh
# Usage: ./program_fpga.sh [bitfile.bit]

set -e

# Default bitfile path
DEFAULT_BITFILE="/home/damith/Research/repos/chipyard_genesys2/chipyard/fpga/bitstream_copy/RocketConfig.bit"

# Check input argument - use default if none provided
if [ $# -eq 0 ]; then
    BITFILE="$DEFAULT_BITFILE"
    echo "No bitfile specified, using default: $BITFILE"
elif [ $# -eq 1 ]; then
    BITFILE="$1"
else
    echo "Usage: $0 [bitfile.bit]"
    echo "If no bitfile is provided, the default will be used: $DEFAULT_BITFILE"
    exit 1
fi

# Check if bitfile exists
if [ ! -f "$BITFILE" ]; then
    echo "Error: Bit file '$BITFILE' not found!"
    exit 1
fi

# Check if vivado is in PATH
if ! command -v vivado &> /dev/null; then
    echo "Vivado not found in PATH. Please adjust PATH or install Vivado."
    exit 1
fi

echo "Programming FPGA with bitstream: $BITFILE"

# Create temporary TCL script
TCL_SCRIPT=$(mktemp)

# Set up cleanup trap to remove temporary file on exit
trap "rm -f '$TCL_SCRIPT'" EXIT
cat > "$TCL_SCRIPT" <<EOF
open_hw
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device [current_hw_device]
set_property PROGRAM.FILE {$BITFILE} [current_hw_device]
program_hw_devices [current_hw_device]
exit
EOF

# Run Vivado with the TCL script
vivado -mode batch -source "$TCL_SCRIPT"

echo "FPGA programming complete!"