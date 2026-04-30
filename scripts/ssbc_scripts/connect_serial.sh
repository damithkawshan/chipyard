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

DEVICE="/dev/ttyUSB1"
BAUDRATE="115200"
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
        echo "Starting picocom... (Ctrl+A, Ctrl+X to exit)"
        picocom -b $BAUDRATE $LOG_OPTS $DEVICE
        ;;
    2)
        echo "Starting screen... (Ctrl+A, K to exit)"
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
        echo "Invalid choice. Using picocom..."
        picocom -b $BAUDRATE $LOG_OPTS $DEVICE
        ;;
esac
