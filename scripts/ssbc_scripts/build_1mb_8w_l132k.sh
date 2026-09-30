#!/bin/bash
# build_1mb_8w_l132k.sh — build single-core 1MB (1024KB) 8-way SBC+PLRU bitstream, 32 kB 8-way L1.
CY=/home/damith/Research/repos/chipyard_performance_eval/chipyard
ST=$CY/fpga/bitstream_storage
STAMP=$(date +%Y-%m-%d)

CFG=FPGASingleRocketVCU118L132K1024K8WL2ConfigSBCPLRU
TAG="1MB-8way-L1-32K8W-${1:?usage: $0 <tag, e.g. control-013c0>}"
GEN=$CY/fpga/generated-src/chipyard.fpga.vcu118.VCU118FPGATestHarness.$CFG
OUT=$ST/$CFG-$TAG-$STAMP

{ echo "built: $(date -Is)"
  echo "chipyard HEAD: $(git -C $CY rev-parse HEAD)"
  echo "L2 HEAD: $(git -C $CY/generators/rocket-chip-inclusive-cache rev-parse HEAD) branch $(git -C $CY/generators/rocket-chip-inclusive-cache branch --show-current)"
  echo "config: $CFG"
  echo "geometry: 1024 KB (1 MB), 8 ways, 64 B lines -> 2048 sets; L1 D/I 32 KB 8-way"
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
