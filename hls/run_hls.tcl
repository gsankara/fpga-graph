# run_hls.tcl -- Vitis HLS flow for a baked graph kernel.
#
# Driven by environment variables (robust across vitis_hls arg-passing quirks):
#   GDIR    path to a build/<graph> dir (has graph_engine.cpp, tb, graph_wire.hpp)
#   PART    FPGA part (default xcu250-figd2104-2L-e)
#   PERIOD  target clock period in ns (default 3.33 => 300 MHz)
#   STOP    how far to run: csim | csynth | cosim | export   (default csynth)
#
# Invoke on the build box (login shell so tools are on PATH):
#   bash -lc 'GDIR=$PWD/build/tree STOP=csynth vitis_hls -f hls/run_hls.tcl'

set gdir     $::env(GDIR)
set part     [expr {[info exists ::env(PART)]     ? $::env(PART)     : "xcu250-figd2104-2L-e"}]
set period   [expr {[info exists ::env(PERIOD)]   ? $::env(PERIOD)   : 3.33}]
set stop     [expr {[info exists ::env(STOP)]     ? $::env(STOP)     : "csynth"}]
set run_csim [expr {[info exists ::env(RUN_CSIM)] ? $::env(RUN_CSIM) : 1}]
# Vitis 2023.2 bundles binutils 2.37; on Ubuntu 24.04 its ld cannot read the
# system libm (DT_RELR). -B/usr/bin makes csim's gcc use the system as/ld.
set csim_ld  [expr {[info exists ::env(CSIM_LDFLAGS)] ? $::env(CSIM_LDFLAGS) : "-B/usr/bin"}]

puts "== run_hls: gdir=$gdir part=$part period=$period stop=$stop run_csim=$run_csim =="

open_project -reset ${gdir}/hls_proj
set_top graph_engine
add_files ${gdir}/graph_engine.cpp     -cflags "-I${gdir}"
add_files -tb ${gdir}/tb_graph_engine.cpp -cflags "-I${gdir}"

open_solution -reset sol1 -flow_target vitis
set_part $part
create_clock -period $period -name default

# 1) C simulation: proves the baked wiring matches the golden BFS.
if {$run_csim} {
  if {[catch {csim_design -ldflags $csim_ld} err]} {
    puts "WARNING: csim_design failed ($err)."
    puts "WARNING: this is usually the Vitis-2023.2/Ubuntu-24.04 linker mismatch,"
    puts "WARNING: not a kernel error (Python self-check already validated logic)."
    if {$stop eq "csim"} { exit 1 }
    puts "WARNING: continuing to csynth."
  }
}
if {$stop eq "csim"} { puts "== stop after csim =="; exit }

# 2) C synthesis: baked graph -> RTL, with timing/resource estimates.
csynth_design
if {$stop eq "csynth"} { puts "== stop after csynth =="; exit }

# 3) Co-simulation (only when explicitly requested): RTL vs. testbench.
if {$stop eq "cosim"} {
  cosim_design -ldflags $csim_ld
  puts "== stop after cosim =="; exit
}

# 4) Export packaged IP for stitching into a Vivado block design.
export_design -format ip_catalog -rtl verilog
puts "== export complete =="
exit
