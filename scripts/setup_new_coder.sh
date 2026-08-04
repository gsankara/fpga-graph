#!/bin/bash
# setup_new_coder.sh -- bring up the fpga-graph U280 build on a fresh instance.
#
#   bash setup_new_coder.sh /path/to/xilinx-u280-...-dev_...deb
#
# Idempotent. Clones the repo (if needed), extracts the U280 dev platform,
# checks toolchain/OS, and prints the exact build command.
set -e
DEB="${1:?usage: setup_new_coder.sh <path-to-u280-dev.deb>}"

# 1. source files
if [ ! -d ~/fpga-routing-graph ]; then
  git clone https://github.com/gsankara/fpga-graph.git ~/fpga-routing-graph
fi
cd ~/fpga-routing-graph

# 2. U280 development platform (dpkg -x = extract, no root)
rm -rf ~/u280dev && mkdir -p ~/u280dev
dpkg -x "$DEB" ~/u280dev
XPFM=$(find ~/u280dev -name '*.xpfm' | head -1)
echo "platform: $XPFM"

# 3. Vivado single-thread init (harmless everywhere)
mkdir -p ~/.Xilinx/Vivado
cp -f scripts/vivado_init.tcl ~/.Xilinx/Vivado/Vivado_init.tcl

# 4. environment sanity
echo "----- environment -----"
grep PRETTY_NAME /etc/os-release
echo "glibc: $(ldd --version | head -1)"
if command -v v++ >/dev/null 2>&1; then
  echo "v++: $(v++ --version 2>/dev/null | head -1)"
else
  echo "WARNING: v++ not on PATH -- run inside a login shell (bash -lc) or source"
  echo "         /tools/Xilinx/Vitis/<ver>/settings64.sh"
fi
case "$(grep -oE '24\.04' /etc/os-release | head -1)" in
  24.04) echo "NOTE: Ubuntu 24.04 detected -> Vivado 2023.2 unsupported; build_graph.sh"
         echo "      auto-LD_PRELOADs tcmalloc as a workaround (may still be fragile).";;
  *)     echo "OS looks supported for Vivado 2023.2.";;
esac

echo "----- ready -----"
echo "build one:   bash scripts/build_graph.sh tree"
echo "build all:   bash scripts/build_all_seq.sh   (tree, ring16, then capacity sweep)"
echo "(the XPFM path in those scripts assumes ~/u280dev/opt/xilinx/platforms/...;"
echo " it matches this extraction, so no edit needed.)"
