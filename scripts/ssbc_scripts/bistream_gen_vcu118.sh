
REPO_DIR=/home/damith/Research/repos/chipyard_performance_eval/chipyard


source "$REPO_DIR/env.sh"


VCU118CONFIG=QuadRocketVCU118Config

FPGA_BUILD_DIR="$REPO_DIR/fpga/"


cd "$FPGA_BUILD_DIR"


# build bitstream and capture logs
make -j20 SUB_PROJECT=vcu118 CONFIG=$VCU118CONFIG bitstream