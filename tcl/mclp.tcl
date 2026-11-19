# MCLP, Multi-Channel Load-cell Platform (Zynq-7000 / ZC702) - Vivado project creation script
# Vivado 2025.1
#
# Usage (from anywhere):
#   vivado -mode batch -source tcl/mclp.tcl
#   vivado -mode batch -source tcl/mclp.tcl -tclargs --project_name foo --build_dir /tmp/x
#   vivado -mode batch -source tcl/mclp.tcl -tclargs --project_name mclp_dma --sim dma --simulate
#
# Everything under build/ is generated and can be deleted at any time.
# Sources are picked up by glob: rtl/, xdc/, coeff/*.mem, tb/system/ or tb/dma/ (sim only), tcl/*_bd.tcl.
# AMD IP outside the block design comes from tcl/ip.tcl.
# --sim system (default): the system test, with stand-ins for the block design and the MMCM.
# --sim dma: the DMA test, with the real block design (PS7 as the Zynq-7000 VIP, AXI DMA, SmartConnects);
#   give it its own --project_name, since it keeps the block design in simulation.

# ==============================================================================
# CONFIGURATION
# ==============================================================================

set origin_dir   [file normalize [file dirname [info script]]/..]
set proj_name    "mclp"
set build_dir    "$origin_dir/build"
set part         "xc7z020clg484-1"
set board_part   "xilinx.com:zc702:part0:1.4"
set top_module   "mclp_top"
set sim          "system"
set simulate     0

proc print_help {} {
	puts "Usage: vivado -mode batch -source tcl/mclp.tcl \[-tclargs <options>\]"
	puts "  --origin_dir <path>    Repo root (default: parent of this script)"
	puts "  --project_name <name>  Project name (default: mclp)"
	puts "  --build_dir <path>     Where the project is created (default: <origin_dir>/build)"
	puts "  --sim <system|dma>     Simulation set (default: system)"
	puts "  --simulate             Run the behavioral simulation after creating the project"
	puts "  --help                 Show this help"
	exit 0
}

for {set i 0} {$i < $::argc} {incr i} {
	switch -- [lindex $::argv $i] {
		"--origin_dir"   { set origin_dir [file normalize [lindex $::argv [incr i]]] }
		"--project_name" { set proj_name  [lindex $::argv [incr i]] }
		"--build_dir"    { set build_dir  [file normalize [lindex $::argv [incr i]]] }
		"--sim"          { set sim        [lindex $::argv [incr i]] }
		"--simulate"     { set simulate   1 }
		"--help"         { print_help }
		default          { error "Unknown option '[lindex $::argv $i]'" }
	}
}
if {$sim ni {system dma}} { error "--sim must be system or dma" }

if {![string match "2025.1*" [version -short]]} {
	puts "WARNING: BD scripts were generated with Vivado 2025.1, running [version -short]"
}

# ==============================================================================
# PROJECT
# ==============================================================================

set proj_dir "$build_dir/$proj_name"
puts "Creating $proj_name in $proj_dir"
create_project $proj_name $proj_dir -part $part -force
set_property board_part $board_part [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property simulator_language Mixed [current_project]

# ==============================================================================
# SOURCES
# ==============================================================================

proc src {pattern} { glob -nocomplain -directory $::origin_dir {*}$pattern }

set rtl [src {rtl/*.v rtl/*.sv rtl/*.vhd rtl/*.vhdl}]
set xdc [src {xdc/*.xdc}]
set mem [src {coeff/*.mem}]
if {$sim eq "system"} {
	set tb     [src {tb/system/*.v tb/system/*.sv}]
	set tb_top mclp_top_tb
} else {
	set tb     [concat [src {tb/system/ad7190_model.sv tb/system/clk_wiz_0_stub.sv}] [src {tb/dma/*.sv}]]
	set tb_top mclp_dma_tb
}

if {[llength $rtl]} { add_files -norecurse -fileset sources_1 $rtl }
if {[llength $xdc]} { add_files -norecurse -fileset constrs_1 $xdc }
if {[llength $mem]} { add_files -norecurse -fileset sources_1 $mem }
if {[llength $tb]}  { add_files -norecurse -fileset sim_1 $tb }
puts "Added [llength $rtl] rtl, [llength $xdc] xdc, [llength $mem] mem, [llength $tb] tb files"

source $origin_dir/tcl/ip.tcl
# tb/system/clk_wiz_0_stub.sv stands in for the MMCM in simulation: the core's model toggles a 1 GHz VCO,
# too slow for the system test
foreach ip {clk_wiz_0} {
	set_property used_in_simulation false [get_files -norecurse $ip.xci]
}

# ==============================================================================
# BLOCK DESIGNS  (tcl/*_bd.tcl, written by: write_bd_tcl -force tcl/<name>_bd.tcl)
# ==============================================================================

foreach bd_script [lsort [src {tcl/*_bd.tcl}]] {
	puts "Sourcing [file tail $bd_script]"
	source $bd_script
	set bd [current_bd_design -quiet]
	if {$bd eq ""} { error "[file tail $bd_script] did not create a block design" }
	set bd_file [get_files -norecurse [get_property NAME $bd].bd]
	close_bd_design $bd
	set wrapper [make_wrapper -files $bd_file -top]
	add_files -norecurse -fileset sources_1 $wrapper
	# system test: tb/system/zynq_ps_wrapper_stub.sv stands in for the block design in simulation
	if {$sim eq "system"} {
		set_property used_in_simulation false $bd_file
		set_property used_in_simulation false [get_files -norecurse $wrapper]
	}
}

set_property top $top_module [get_filesets sources_1]
update_compile_order -fileset sources_1
if {[llength $tb]} {
	set_property top $tb_top [get_filesets sim_1]
	set_property -name xsim.simulate.runtime -value [expr {$sim eq "system" ? "600ms" : "60ms"}] \
		-objects [get_filesets sim_1]
}

puts ""
puts "SUCCESS: [get_property DIRECTORY [current_project]]/$proj_name.xpr"
if {$simulate} {
	launch_simulation -simset sim_1 -mode behavioral
	close_sim
	puts "Simulation log: [get_property DIRECTORY [current_project]]/$proj_name.sim/sim_1/behav/xsim/simulate.log"
} else {
	puts "Next: launch_runs impl_1 -to_step write_bitstream -jobs 8"
}
