#!/bin/bash
# build_dual_16w_8w.sh — build dual-core 16-way and 8-way 64KB SBC+PLRU bitstreams sequentially.
CY=/home/damith/Research/repos/chipyard_performance_eval/chipyard
ST=$CY/fpga/bitstream_storage
STAMP=$(date +%Y-%m-%d)

DUAL16=FPGADualRocketVCU118L18K64K16WL2ConfigSBCPLRU
DUAL8=FPGADualRocketVCU118L18K64K8WL2ConfigSBCPLRU

build_and_archive() {
    local CFG="$1"
    local TAG="$2"  # short human tag for provenance filename
    local GEN=$CY/fpga/generated-src/chipyard.fpga.vcu118.VCU118FPGATestHarness.$CFG
    local OUT=$ST/$CFG-$TAG-$STAMP

    { echo "built: $(date -Is)"
      echo "chipyard HEAD: $(git -C $CY rev-parse HEAD)"
      echo "L2 HEAD: $(git -C $CY/generators/rocket-chip-inclusive-cache rev-parse HEAD) branch $(git -C $CY/generators/rocket-chip-inclusive-cache branch --show-current)"
      echo "config: $CFG"
      (cd $CY/generators/rocket-chip-inclusive-cache/design/craft/inclusivecache/src && sha256sum *.scala)
    } > $OUT.provenance.txt

    echo "[$(date '+%F %T')] BUILD start $CFG"
    $CY/scripts/ssbc_scripts/bistream_gen_vcu118.sh $CFG
    RC=$?; echo "BUILD_RC=$RC"

    local BIT=$GEN/obj/VCU118FPGATestHarness.bit
    if [ $RC -ne 0 ] || [ ! -f $BIT ]; then
        echo "BUILD FAILED for $CFG - nothing archived"
        return 1
    fi

    cp -p $BIT $OUT.bit
    mkdir -p $OUT.reports && cp -p $GEN/obj/report/* $OUT.reports/ 2>/dev/null
    SHA=$(sha256sum $OUT.bit | awk '{print $1}')
    echo "sha256 $SHA" >> $OUT.provenance.txt
    echo "SHA256=$SHA"
    awk '/WNS\(ns\)/{getline; getline; print "timing WNS TNS ... :", $0; exit}' $OUT.reports/timing.txt 2>/dev/null
    grep -m1 'Violations found' $OUT.reports/drc.txt 2>/dev/null
    echo "[$(date '+%F %T')] ARCHIVED -> $OUT.bit"
}

build_and_archive "$DUAL16" "dual16w" && \
build_and_archive "$DUAL8"  "dual8w"

echo "[$(date '+%F %T')] ALL DONE"
