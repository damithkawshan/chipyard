import pexpect
import sys
import time
import re
import os

def run_test(bitstream, bit_hash, run_num):
    log_file = open(f'bisection_{bit_hash}.log', 'w')
    def log(msg):
        print(msg)
        log_file.write(msg + '\n')
        log_file.flush()

    log(f"=== Testing {bitstream} ===")
    
    # BOOT A - R1
    log("Starting BOOT A (R1)...")
    cmd = f"./tmp.exp -hangtest migoff -bit {bitstream} -iters 1"
    child = pexpect.spawn(cmd, encoding='utf-8', timeout=1800)
    child.logfile = sys.stdout
    
    try:
        child.expect("ITER_RC=0", timeout=1200)
        log("BOOT A (R1) finished successfully.")
        child.expect(pexpect.EOF)
    except Exception as e:
        log(f"BOOT A (R1) failed or timed out: {e}")
        return "ERROR_R1"
        
    # BOOT A - R2
    log("Connecting for BOOT A (R2)...")
    child = pexpect.spawn("./connect_serial.sh", encoding='utf-8', timeout=60)
    # Wait for prompt
    child.expect("root@zynq:~#")
    
    # Setup R2
    child.sendline("/root/sbc_read --policy=random")
    child.expect("root@zynq:~#")
    child.sendline("/root/sbc_read --reset-all --migrate=on")
    child.expect("root@zynq:~#")
    child.sendline("/root/sbc_read | head -1")
    child.expect("root@zynq:~#")
    sbc_out = child.before
    if "migrate : ON" not in sbc_out:
        log("ERROR: migrate not ON!")
        return "ERROR_MIGRATE_NOT_ON"
        
    log("Running R2 heartbeat loop...")
    child.sendline("cd /root/test_dir/520.omnetpp_r_run_ref")
    child.expect("root@zynq.*#")
    child.sendline("/root/sbc_read --zero > /dev/null")
    child.expect("root@zynq.*#")
    
    r2_script = """HS=$(date +%s)
./omnetpp_r_base.riscv-64 -c General -r 0 --sim-time-limit=0.002s > wl.out 2> wl.err &
W=$!
while kill -0 $W 2>/dev/null; do
  echo "HB t=$(( $(date +%s) - HS ))s"
  /root/sbc_read | head -1
  sleep 60
done
wait $W; echo "ITER_RC=$? ITER_SECS=$(( $(date +%s) - HS ))"
"""
    child.sendline(r2_script)
    
    # Now monitor heartbeats
    hung = False
    last_heartbeats = []
    
    while True:
        try:
            # We expect either a heartbeat or ITER_RC=0
            index = child.expect(["HB t=.*?\r\n.*?\r\n", "ITER_RC=0 ITER_SECS=[0-9]+"], timeout=90)
            if index == 0:
                hb = child.match.group(0)
                log(f"Heartbeat: {hb.strip()}")
                last_heartbeats.append(hb.strip())
                if len(last_heartbeats) > 5:
                    last_heartbeats.pop(0)
            elif index == 1:
                log("R2 completed successfully!")
                break
        except pexpect.TIMEOUT:
            log("TIMEOUT waiting for heartbeat! HUNG!")
            hung = True
            break
            
    if hung:
        log("Capturing §6 state...")
        log("Last 5 heartbeats:")
        for hb in last_heartbeats:
            log(hb)
            
        log("Trying sbc_read 3 times...")
        for i in range(3):
            child.sendline("/root/sbc_read | head -1")
            try:
                child.expect("\r\n", timeout=10)
                child.expect("\r\n", timeout=10)
                log(f"sbc_read {i}: {child.before.strip()}")
            except:
                log(f"sbc_read {i} timed out")
            time.sleep(30)
            
        log("Testing Ctrl-C...")
        child.send('\x03') # Ctrl-C
        try:
            child.expect("root@zynq.*#", timeout=10)
            log("Prompt returned after Ctrl-C")
        except:
            log("No prompt after Ctrl-C")
            
        log("Testing Enter twice...")
        child.send('\r')
        try:
            child.expect("\r\n", timeout=5)
            log("Enter 1 echoed")
        except:
            log("Enter 1 did not echo")
        child.send('\r')
        try:
            child.expect("\r\n", timeout=5)
            log("Enter 2 echoed")
        except:
            log("Enter 2 did not echo")
            
        # R2 hung. We need to run BOOT B (R3)
        child.close()
        log("R2 wedges. Returning 'FAIL_R2_WEDGE'. Must run R3 next.")
        return "FAIL_R2_WEDGE"
    
    child.close()
    return "PASS_R2"

# TODO: Add R3 logic if R2 wedges, or if R2 completes (to check R3 completion).
