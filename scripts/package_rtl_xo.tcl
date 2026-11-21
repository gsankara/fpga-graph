# package_rtl_xo.tcl -- wrap the RTL kernel as a .xo for v++ -l.
#
#   vivado -mode batch -source scripts/package_rtl_xo.tcl -tclargs \
#          <out.xo> <graph_or.v> <part> <N> <REG_EVERY>
#
# Only the three RTL files and kernel.xml go in; there is no HLS step in this
# flow at all, which is the point of ask 2's second half.
if {[llength $argv] < 5} {
    puts "ERROR usage: ... -tclargs <out.xo> <graph_or.v> <part> <N> <REG_EVERY>"
    exit 1
}
set out_xo    [lindex $argv 0]
set graph_or_v [lindex $argv 1]
set part      [lindex $argv 2]
set gN        [lindex $argv 3]
set gREG      [lindex $argv 4]

set root [file normalize [file dirname [info script]]/..]
set tmp  [file dirname $out_xo]/_pkg
file delete -force $tmp
file mkdir $tmp

create_project -force pkg_graph_or $tmp -part $part

# or_tree.v first: graph_or instantiates it, and Vivado's elaboration order
# follows the file order for plain .v with no library declaration.
add_files -norecurse [list \
    $root/rtl/or_tree.v \
    $graph_or_v \
    $root/rtl/graph_engine_rtl.v ]
set_property top graph_engine_part [current_fileset]

# N and REG_EVERY are generics on the kernel top; graph_or carries its own
# defaults from the generator, so these two must agree with the .v that was
# generated or the state width silently truncates.
set_property generic [list N=$gN REG_EVERY=$gREG] [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $tmp/ip -vendor fabric -library hls \
    -taxonomy /KernelIP -import_files -set_current true
set core [ipx::current_core]
set_property core_revision 1 $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core

package_xo -xo_path $out_xo -kernel_name graph_engine_part \
           -ip_directory $tmp/ip -kernel_xml $root/rtl/kernel.xml

if {[file exists $out_xo]} {
    puts "PACKAGE_RESULT status=ok xo=$out_xo bytes=[file size $out_xo]"
} else {
    puts "PACKAGE_RESULT status=fail reason=no_xo"
    exit 2
}
