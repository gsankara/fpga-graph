# FPGA routing-graph engine -- build orchestration.
#
# Local (Windows/any): `make gen` runs the pure-Python generator + self-check.
# On the build box (csg-fpga-compile.coder, login shell): `make csim|csynth|
# cosim|xclbin` drive Vitis HLS / v++.
#
#   make gen     GRAPH=tree SEED=0 MODE=latch
#   make csim    GRAPH=tree
#   make csynth  GRAPH=tree PART=xcu250-figd2104-2L-e PERIOD=3.33
#   make cosim   GRAPH=tree
#   make xclbin  GRAPH=tree PLATFORM=<xpfm>       # long (hours); full bitstream

GRAPH   ?= tree
SEED    ?= 0
MODE    ?= latch
PART    ?= xcu280-fsvh2892-2L-e
PERIOD  ?= 3.33
TARGET  ?= hw
# Must match the shell installed on the machine that will run the card.
# List candidates on that machine with:  platforminfo -l
PLATFORM ?= xilinx_u280_gen3x16_xdma_1_202211_1
PY      ?= python3
XILINX_XRT ?= /opt/xilinx/xrt

ROOT    := $(abspath .)
BUILD   := $(ROOT)/build/$(GRAPH)
EDGES   := examples/$(GRAPH).edges

.PHONY: gen csim csynth cosim export xclbin host run clean help

help:
	@echo "targets: gen csim csynth cosim export xclbin host run clean"
	@echo "vars:    GRAPH SEED MODE PART PERIOD PLATFORM TARGET XILINX_XRT"

gen:
	$(PY) graphgen/gen_hls.py $(EDGES) --seed $(SEED) --mode $(MODE) --name $(GRAPH)

csim: gen
	GDIR=$(BUILD) PART=$(PART) PERIOD=$(PERIOD) STOP=csim   vitis_hls -f hls/run_hls.tcl

csynth: gen
	GDIR=$(BUILD) PART=$(PART) PERIOD=$(PERIOD) STOP=csynth vitis_hls -f hls/run_hls.tcl

cosim: gen
	GDIR=$(BUILD) PART=$(PART) PERIOD=$(PERIOD) STOP=cosim  vitis_hls -f hls/run_hls.tcl

export: gen
	GDIR=$(BUILD) PART=$(PART) PERIOD=$(PERIOD) STOP=export vitis_hls -f hls/run_hls.tcl

# Full Alveo bitstream (xclbin). Requires the target platform installed; slow
# (hardware P&R = ~1-2 h even for a tiny kernel, the shell dominates).
xclbin: gen
	v++ -c -t $(TARGET) --platform $(PLATFORM) -k graph_engine \
	    -I$(BUILD) $(BUILD)/graph_engine.cpp -o $(BUILD)/graph_engine.xo
	v++ -l -t $(TARGET) --platform $(PLATFORM) \
	    $(BUILD)/graph_engine.xo -o $(BUILD)/graph_engine.xclbin

# XRT host program (build once, reuse for every graph).
host:
	g++ -std=c++17 -O2 host/host.cpp -o build/host_graph \
	    -I$(XILINX_XRT)/include -L$(XILINX_XRT)/lib -lxrt_coreutil -pthread

# Load the xclbin on a real card and self-check against the golden trace.
run:
	build/host_graph $(BUILD)/graph_engine.xclbin $(BUILD)/expected.txt

clean:
	rm -rf $(ROOT)/build/*/hls_proj $(ROOT)/build/*/*.xo $(ROOT)/build/*/*.xclbin \
	       $(ROOT)/build/*/*.log vitis_hls.log
