#!/bin/bash
# sdboot_linux.sh – Write a FireMarshal Linux image to SD card for
#                    booting on VCU118 RocketChip.
#
# Features:
#   - Verifies the FireMarshal Linux binary exists before writing
#   - Automatically unmounts any mounted SD card partitions
#   - Writes the Linux image to SD card at sector 34
#   - Optionally partitions the SD card if --format-data is given and partitions are missing
#   - Optionally formats the second partition for persistent data (ext4 or hfs)
#   - Powers off the SD card reader after writing (if supported)
#   - Provides verification by dumping the first sector of the written image
#
# Boot flow:
#   1. VCU118 bootrom (sdboot) initialises UART & SD, prints INIT/CMD*/LOADING…
#   2. sdboot reads raw binary from SD sector 34 into DRAM at 0x80000000
#   3. sdboot prints BOOT, does fence.i, then jumps to 0x80000000
#   4. Linux kernel boots. Login: root / fpga
#
# Prerequisites:
#   - FireMarshal br-base-bin-nodisk-flat already built
#   - Build commands:
#       cd $CHIPYARD_DIR/software/firemarshal
#       ./marshal -v -d build br-base.json
#       ./marshal -v -d install -t prototype br-base.json
#   - SD card plugged in (partitioning/formatting optional)
#   - UART connected at 115200 8N1 to see output
#
# Usage:  bash sdboot_linux.sh [/dev/sdX] [--format-data [ext4|hfs]]

set -e

# ── Configuration ──────────────────────────────────────────────────
SDDEV="${1:-/dev/sdc}"                 # SD card block device (override via $1)
SECTOR=34                             # must match BBL_PARTITION_START_SECTOR in sd.c

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHIPYARD_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LINUX_BIN="${CHIPYARD_DIR}/software/firemarshal/images/prototype/br-base/br-base-bin-nodisk-flat"

# ── 1. Verify the Linux binary exists ──────────────────────────────
if [ ! -f "$LINUX_BIN" ]; then
    echo "ERROR: Linux binary not found at:"
    echo "  $LINUX_BIN"
    echo ""
    echo "Build it first with FireMarshal:"
    echo "  cd $CHIPYARD_DIR/software/firemarshal"
    echo "  ./marshal -v -d build br-base.json"
    echo "  ./marshal -v -d install -t prototype br-base.json"
    exit 1
fi

echo "── Linux binary ──"
ls -lh "$LINUX_BIN"

# ── 2. Verify SD card ─────────────────────────────────────────────
if [ ! -b "$SDDEV" ]; then
    echo "ERROR: SD card device $SDDEV not found."
    echo "Usage: $0 [/dev/sdX]"
    exit 1
fi

echo ""
echo "── SD card layout ──"
lsblk "$SDDEV"

# ── 3. Unmount any mounted partitions ─────────────────────────────
for m in $(lsblk -ln -o NAME,MOUNTPOINT "$SDDEV" | awk '$2!="" {print "/dev/"$1}'); do
    echo "Unmounting $m"
    sudo umount "$m" || true
done

# ── 4. Write Linux binary to SD card at sector 34 ─────────────────
echo ""
echo "── Writing Linux image to SD card (${SDDEV}, sector ${SECTOR}) ──"
sudo dd if="$LINUX_BIN" of="$SDDEV" bs=512 seek=${SECTOR} conv=notrunc status=progress

sync

# ── 5. Verify: dump first sector of what we wrote ─────────────────
echo ""
echo "── Verification (first 512 bytes at sector ${SECTOR}) ──"
sudo dd if="$SDDEV" bs=512 skip=${SECTOR} count=1 status=none | hexdump -C | head -20

# ── 6. Optionally partition the SD card if --format-data is given and partitions are missing ──
if [[ "$2" == "--format-data" ]]; then
    if ! lsblk -ln "$SDDEV" 2>/dev/null | grep -q "^$(basename $SDDEV)2"; then
        echo ""
        echo "── Creating partitions on $SDDEV ──"
        sudo parted -s "$SDDEV" mklabel gpt
        # Partition 1: starts at sector 34, size 512MiB
        sudo parted -s "$SDDEV" unit s mkpart primary 34 1048613
        # Partition 2: rest of the card
        sudo parted -s "$SDDEV" unit s mkpart primary 1048614 100%
        sudo partprobe "$SDDEV"
        sleep 1
        echo "Partitions created:"
        lsblk "$SDDEV"
    fi
fi

# ── 7. Optionally format the second partition for persistent data ──
if [[ "$2" == "--format-data" ]]; then
    FSTYPE="${3:-ext4}"
    DATAPART="${SDDEV}2"
    echo ""
    echo "── Formatting $DATAPART as $FSTYPE ──"
    if [ "$FSTYPE" = "ext4" ]; then
        sudo mkfs.ext4 -L "PrototypeData" "$DATAPART"
    elif [ "$FSTYPE" = "hfs" ]; then
        sudo mkfs.hfs -v "PrototypeData" "$DATAPART"
    else
        echo "ERROR: Unknown filesystem type: $FSTYPE"
        exit 1
    fi
    echo "Done formatting $DATAPART."
fi

# safely power off the SD reader if possible
if command -v udisksctl >/dev/null 2>&1; then
    echo ""
    echo "Powering off SD reader..."
    sudo udisksctl power-off -b "$SDDEV" || true
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Done!  Insert SD card into VCU118 and reset the board."
echo "  Connect UART at 115200 8N1:"
echo ""
echo "    screen -S FPGA_UART /dev/ttyUSB1 115200"
echo ""
echo "  Login: root / fpga"
echo "══════════════════════════════════════════════════════════"
