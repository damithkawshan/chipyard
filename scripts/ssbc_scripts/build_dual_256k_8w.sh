#!/bin/bash
# build_dual_256k_8w.sh - build the dual-core 256 KB 8-way SBC+PLRU bitstream and archive it.
# The dual of the single-core bitstream the 2026-10-02 LU sweep ran on: same L1, same L2 geometry,
# same policy, two cores. bistream_gen_vcu118.sh deletes this config's generated-src dir first
# (never "make clean", which would wipe every other config's bitstream too).
CY=/home/damith/Research/repos/chipyard_performance_eval/chipyard
ST=$CY/fpga/bitstream_storage
STAMP=$(date +%Y-%m-%d)

CFG=FPGADualRocketVCU118L18K256K8WL2ConfigSBCPLRU
TAG="dual-256KB-8way"
GEN=$CY/fpga/generated-src/chipyard.fpga.vcu118.VCU118FPGATestHarness.$CFG
OUT=$ST/$CFG-$TAG-$STAMP

mkdir -p "$ST"

{ echo "built: $(date -Is)"
  echo "chipyard HEAD: $(git -C $CY rev-parse HEAD)"
  echo "L2 HEAD: $(git -C $CY/generators/rocket-chip-inclusive-cache rev-parse HEAD) branch $(git -C $CY/generators/rocket-chip-inclusive-cache branch --show-current)"
  echo "config: $CFG"
  echo "geometry: 2 cores, 256 KB, 8 ways, 64 B lines -> 512 sets"
  (cd $CY/generators/rocket-chip-inclusive-cache/design/craft/inclusivecache/src && sha256sum *.scala)
} > $OUT.provenance.txt

echo "[$(date '+%F %T')] BUILD start $CFG"
$CY/scripts/ssbc_scripts/bistream_gen_vcu118.sh $CFG
RC=$?; echo "BUILD_RC=$RC"

BIT=$GEN/obj/VCU118FPGATestHarness.bit
if [ $RC -ne 0 ] || [ ! -f $BIT ]; then
    echo "BUILD FAILED for $CFG - nothing archived"
    exit 1
fi

cp -p $BIT $OUT.bit
mkdir -p $OUT.reports && cp -p $GEN/obj/report/* $OUT.reports/ 2>/dev/null
SHA=$(sha256sum $OUT.bit | awk '{print $1}')
echo "sha256 $SHA" >> $OUT.provenance.txt
echo "SHA256=$SHA"
awk '/WNS\(ns\)/{getline; getline; print "timing WNS TNS ... :", $0; exit}' $OUT.reports/timing.txt 2>/dev/null
grep -m1 'Violations found' $OUT.reports/drc.txt 2>/dev/null
echo "[$(date '+%F %T')] ARCHIVED -> $OUT.bit"
echo "[$(date '+%F %T')] ALL DONE"
