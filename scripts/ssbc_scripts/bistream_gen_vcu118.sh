
REPO_DIR=/home/damith/Research/repos/chipyard_performance_eval/chipyard


source "$REPO_DIR/env.sh"


# VCU118CONFIG=SingleRocketVCU118L18K256K16WL2ConfigTLCounter
# VCU118CONFIG=QuadRocketVCU118ConfigSatTLCounter256KL2Config
# VCU118CONFIG=FPGASingleRocketVCU118L18K256K16WL2ConfigSBCPhase2Finish  # stale: shadow+debug ON
# VCU118CONFIG=FPGASingleRocketVCU118L18K256K16WL2ConfigNoSbc            # SBC-off baseline twin
VCU118CONFIG=FPGASingleRocketVCU118L18K256K16WL2ConfigSBC

FPGA_BUILD_DIR="$REPO_DIR/fpga/"


cd "$FPGA_BUILD_DIR"


# build bitstream and capture logs
make -j20 SUB_PROJECT=vcu118 CONFIG=$VCU118CONFIG bitstream