#!/bin/bash
# sdboot_linux.sh – Write a FireMarshal Linux image to SD card for
#                    booting on VCU118 RocketChip.
#
# Boot flow:
#   1. VCU118 bootrom (sdboot) initialises UART & SD, prints INIT/CMD*/LOADING…
#   2. sdboot reads raw binary from SD sector 34 into DRAM at 0x80000000
#   3. sdboot prints BOOT, does fence.i, then jumps to 0x80000000
#   4. Linux kernel boots. Login: root / fpga
#
# Prerequisites:
#   - FireMarshal br-base-bin-nodisk-flat already built
#   - SD card plugged in and partitioned (partition 1 starts at sector 34)
#   - UART connected at 115200 8N1 to see output
#
# Usage:  bash sdboot_linux.sh [/dev/sdX]

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
