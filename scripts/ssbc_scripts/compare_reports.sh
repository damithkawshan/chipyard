#!/usr/bin/env bash
# Compare post-route area + timing between two VCU118 builds.
# Usage: ./compare_reports.sh <CONFIG_A> <CONFIG_B>
#   e.g. ./compare_reports.sh FPGASingleRocketVCU118L18K256K16WL2ConfigNoSbc \
#                             FPGASingleRocketVCU118L18K256K16WL2ConfigSBCResetEnabled

REPO_DIR=/home/damith/Research/repos/chipyard_performance_eval/chipyard
GEN="$REPO_DIR/fpga/generated-src"
PREFIX=chipyard.fpga.vcu118.VCU118FPGATestHarness

row() {  # row <util.txt> <instance-name-regex>
  grep -m1 -E "^\| +$2 +\|" "$1" \
    | awk -F'|' '{gsub(/^ +| +$/,"",$2); gsub(/ /,"",$4); gsub(/ /,"",$6); gsub(/ /,"",$8);
                  printf "%8s %8s %8s", $4, $8, $6}'
}

report() {
  local cfg=$1
  local u="$GEN/$PREFIX.$cfg/obj/report/utilization.txt"
  local t="$GEN/$PREFIX.$cfg/obj/report/timing.txt"
  if [ ! -f "$u" ]; then echo "MISSING: $u"; return 1; fi

  echo "######## $cfg"
  echo "  built: $(grep -m1 '^| Date' "$u" | sed 's/.*: //')"
  printf "  %-28s %8s %8s %8s\n" INSTANCE LUT FF LUTRAM
  for inst in VCU118FPGATestHarness chiptop0 coh_wrapper l2 \
              inclusive_cache_bank_sched sbu dss setCopyUnit directory \
              'mshrs_[0-6]' sinkA sinkC sourceD tile_prci_domain; do
    if [ "$inst" = 'mshrs_[0-6]' ]; then
      # MSHRs are 7 separate instances; sum them
      grep -E "^\| +mshrs_[0-6] +\|" "$u" \
        | awk -F'|' '{gsub(/ /,"",$4); gsub(/ /,"",$8); l+=$4; f+=$8}
                     END{printf "  %-28s %8d %8d %8s\n","mshrs_0..6 (sum)",l,f,"-"}'
    else
      printf "  %-28s%s\n" "$inst" "$(row "$u" "$inst")"
    fi
  done

  echo "  -- timing (post-route) --"
  printf "  %-28s %s\n" "design WNS/WHS" \
    "$(grep -A6 '^| Design Timing Summary' "$t" | tail -1 | awk '{print "WNS="$1"  TNS="$2"  failing="$3"  WHS="$5}')"
  # core/uncore domain: worst setup path and who owns it.
  # NB: in the report, "Path Group" precedes "Data Path Delay"/"Logic Levels",
  # so arm on the group line and print once Logic Levels arrives.
  awk '/^Slack \(MET|^Slack \(VIO/{s=$4; armed=0}
       /^  Source:/{src=$2} /^  Destination:/{dst=$2}
       /^  Path Group: *clk_out1_harnessSysPLL$/{armed=1}
       armed && /^  Data Path Delay:/{dpd=""; for(i=4;i<=NF;i++) dpd=dpd" "$i}
       armed && /^  Logic Levels:/{
         ll=""; for(i=3;i<=NF;i++) ll=ll" "$i;
         printf "  %-28s %s\n","core-domain WNS",s;
         printf "  %-28s%s\n","  data path delay",dpd;
         printf "  %-28s%s\n","  logic levels",ll;
         printf "  %-28s %s\n","  from",src;
         printf "  %-28s %s\n","  to",dst; exit}' "$t"
  echo
}

report "$1"
report "$2"
