# MCLP, Multi-Channel Load-cell Platform (Zynq-7000 / ZC702) - Vivado project creation script
# Vivado 2025.1
#
# Usage (from anywhere):
#   vivado -mode batch -source tcl/mclp.tcl
#   vivado -mode batch -source tcl/mclp.tcl -tclargs --project_name foo --build_dir /tmp/x
#   vivado -mode batch -source tcl/mclp.tcl -tclargs --project_name mclp_dma --sim dma --simulate
#
# Everything under build/ is generated and can be deleted at any time.
# mclp_core (rtl/, coeff/*.mem) is packaged as IP first (tcl/package_ip.tcl, into <build_dir>/ip_repo); the
# block design (tcl/*_bd.tcl) instantiates it, and its wrapper is the top. xdc/ holds the pins and timing.
# --sim system (default): the system test; tb/system/mclp_top_wrapper_stub.sv stands in for the block
#   design (PS, MMCM) around the mclp_core RTL.
# --sim dma: the DMA test, with the real block design (PS7 as the Zynq-7000 VIP, AXI DMA, SmartConnects,
#   clocking wizard, the packaged core); give it its own --project_name, since it keeps the block design
#   in simulation.

# ==============================================================================
# CONFIGURATION
# ==============================================================================

set origin_dir   [file normalize [file dirname [info script]]/..]
set proj_name    "mclp"
set build_dir    "$origin_dir/build"
set part         "xc7z020clg484-1"
set board_part   "xilinx.com:zc702:part0:1.4"
set top_module   "mclp_top_wrapper"
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

source $origin_dir/tcl/package_ip.tcl

# ==============================================================================
# PROJECT
# ==============================================================================

set proj_dir "$build_dir/$proj_name"
puts "Creating $proj_name in $proj_dir"
create_project $proj_name $proj_dir -part $part -force
set_property board_part $board_part [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property simulator_language Mixed [current_project]
set_property ip_repo_paths [list "$build_dir/ip_repo"] [current_project]
update_ip_catalog -rebuild

# ==============================================================================
# SOURCES
# ==============================================================================

proc src {pattern} { glob -nocomplain -directory $::origin_dir {*}$pattern }

set rtl [src {rtl/*.v rtl/*.sv rtl/*.vhd rtl/*.vhdl}]
set xdc [src {xdc/*.xdc}]
set mem [src {coeff/*.mem}]
# Synthesis takes mclp_core from the packaged IP; the system test compiles the RTL itself. The RAM images go
# to sim_1 so the simulator finds them in its run directory.
if {$sim eq "system"} {
	set tb     [concat $rtl [src {tb/system/*.v tb/system/*.sv}]]
	set tb_top mclp_top_tb
} else {
	set tb     [concat [src {tb/system/ad7190_model.sv}] [src {tb/dma/*.sv}]]
	set tb_top mclp_dma_tb
}

if {[llength $xdc]} { add_files -norecurse -fileset constrs_1 $xdc }
if {[llength $tb]}  { add_files -norecurse -fileset sim_1 $tb }
if {[llength $mem]} { add_files -norecurse -fileset sim_1 $mem }
puts "Added [llength $xdc] xdc, [llength $tb] tb, [llength $mem] mem files"

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
	# system test: tb/system/mclp_top_wrapper_stub.sv stands in for the block design in simulation
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
