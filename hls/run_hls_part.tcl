# run_hls_part.tcl -- Vitis HLS csynth for a PARTITIONED kernel (design P).
#
# run_hls.tcl cannot be reused: it sets top `graph_engine` and adds
# tb_graph_engine.cpp, while the partitioned kernel's top is
# `graph_engine_part` and its harness is sim/tb_part.cpp. This script is
# csynth-only on purpose -- functional equivalence is established separately by
# compiling the kernel with g++ against sim/ap_int.h and diffing output, which
# needs no Vitis licence and takes seconds instead of an hour.
#
# Driven by environment variables:
#   GDIR    design dir (graph_engine.cpp + graph_wire.hpp)
#   PART    FPGA part (default xcu280-fsvh2892-2L-e, the Alveo U280)
#   PERIOD  target clock period in ns (default 3.33 => 300 MHz)
#
#   GDIR=$PWD/n1000d20_tree vitis_hls -f hls/run_hls_part.tcl

set gdir   $::env(GDIR)
set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xcu280-fsvh2892-2L-e"}]
set period [expr {[info exists ::env(PERIOD)] ? $::env(PERIOD) : 3.33}]

puts "== run_hls_part: gdir=$gdir part=$part period=$period =="

open_project -reset ${gdir}/hls_proj
set_top graph_engine_part
add_files ${gdir}/graph_engine.cpp -cflags "-I${gdir}"

open_solution -reset sol1 -flow_target vitis
set_part $part
create_clock -period $period -name default

csynth_design
puts "== csynth complete =="
exit
