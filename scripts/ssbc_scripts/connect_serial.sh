#!/bin/bash

# Serial connection script for FPGA
# This script handles common serial communication issues

#install dependencies if not present
if ! command -v picocom &> /dev/null
then
    echo "picocom could not be found, installing..."
    sudo apt update
    sudo apt install -y picocom
fi

# sz/rz are what picocom shells out to for file transfer (Ctrl-A Ctrl-S / Ctrl-A Ctrl-R).
if ! command -v sz &> /dev/null || ! command -v rz &> /dev/null
then
    echo "lrzsz (sz/rz) could not be found, installing..."
    sudo apt update
    sudo apt install -y lrzsz
fi

DEVICE="/dev/ttyUSB2"
BAUDRATE="115200"

# ZMODEM file transfer, wired into picocom's Ctrl-A Ctrl-S (send) / Ctrl-A Ctrl-R (receive).
# The board already ships sz/rz - br-base's buildroot config sets BR2_PACKAGE_LRZSZ=y.
#   -b        binary mode. Mandatory: without it an ELF gets mangled by newline translation.
#   -w / -L   small window and packet. This UART has no RTS/CTS, so zmodem's default window
#             overruns the FIFO. Shrinking it is what makes the transfer stable.
#   -E        rz: do not clobber, rename if the file already exists.
# An array, not a string: each --send-cmd value must reach picocom as ONE argument.
XFER_OPTS=(--send-cmd "sz -vv -b -w 1024 -L 128" --receive-cmd "rz -vv -b -E")
LOGDIR="$(dirname "$0")/../logs"
LOGFILE="${LOGDIR}/uart_$(date +%Y%m%d_%H%M%S).log"

echo "FPGA Serial Connection Script"
echo "============================="

# Check if device exists
if [ ! -e "$DEVICE" ]; then
    echo "Error: $DEVICE not found!"
    echo "Available tty devices:"
    ls -la /dev/ttyUSB* 2>/dev/null || echo "No ttyUSB devices found"
    exit 1
fi

# Kill any existing processes using the device
echo "Killing any existing processes using $DEVICE..."
sudo fuser -k $DEVICE 2>/dev/null || true
pkill -f "screen.*ttyUSB" 2>/dev/null || true
pkill -f "picocom.*ttyUSB" 2>/dev/null || true

# Wait a moment
sleep 1

# Reset the device
echo "Resetting serial device..."
stty -F $DEVICE $BAUDRATE raw -echo 2>/dev/null || true

echo "Connecting to $DEVICE at $BAUDRATE baud..."

# Ask about logging
read -p "Enable logging? (y/N): " enable_log
if [[ "$enable_log" =~ ^[Yy]$ ]]; then
    mkdir -p "$LOGDIR"
    echo "Logging UART output to: $LOGFILE"
    LOG_OPTS="--logfile $LOGFILE"
else
    LOG_OPTS=""
fi

echo "Choose connection method:"
echo "1) picocom (recommended)"
echo "2) screen"
echo "3) minicom"
read -p "Enter choice (1-3): " choice

case $choice in
    1)
        echo "Starting picocom..."
        echo "  Ctrl-A Ctrl-X  quit"
        echo "  Ctrl-A Ctrl-S  send a file to the board   (run 'rz -b -E' there first)"
        echo "  Ctrl-A Ctrl-R  pull a file from the board (run 'sz -b <file>' there first)"
        picocom -b $BAUDRATE $LOG_OPTS "${XFER_OPTS[@]}" $DEVICE
        ;;
    2)
        echo "Starting screen... (Ctrl+A, K to exit). Note: no rz/sz file transfer - use picocom for that."
        if [ -n "$LOG_OPTS" ]; then
            echo "Logging via 'script' wrapper..."
            script -f "$LOGFILE" -c "screen $DEVICE $BAUDRATE"
        else
            screen $DEVICE $BAUDRATE
        fi
        ;;
    3)
        echo "Starting minicom..."
        if command -v minicom &> /dev/null; then
            if [ -n "$LOG_OPTS" ]; then
                minicom -D $DEVICE -b $BAUDRATE --capturefile="$LOGFILE"
            else
                minicom -D $DEVICE -b $BAUDRATE
            fi
        else
            echo "minicom not installed. Install with: sudo apt install minicom"
        fi
        ;;
    *)
        echo "Invalid choice. Using picocom (Ctrl-A Ctrl-S send, Ctrl-A Ctrl-R receive, Ctrl-A Ctrl-X quit)..."
        picocom -b $BAUDRATE $LOG_OPTS "${XFER_OPTS[@]}" $DEVICE
        ;;
esac
