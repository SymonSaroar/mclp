# Packages mclp_core (rtl/, with the RAM images in coeff/) as the Vivado IP mclp:ip:mclp_core:2.0 in
# <build_dir>/ip_repo/mclp_core. To use it in another project, add <build_dir>/ip_repo to the project's IP
# repositories (Settings > IP > Repository).
#
# Usage (from anywhere):
#   vivado -mode batch -source tcl/package_ip.tcl
#   vivado -mode batch -source tcl/package_ip.tcl -tclargs --build_dir /tmp/x
#
# tcl/mclp.tcl sources this before it creates its project, with its own origin_dir, build_dir and part.
# The packaging runs in a throwaway project, <build_dir>/ip_pkg, closed at the end.

if {![info exists origin_dir]} {
	set origin_dir [file normalize [file dirname [info script]]/..]
	set build_dir  "$origin_dir/build"
	set part       "xc7z020clg484-1"
	for {set i 0} {$i < $::argc} {incr i} {
		switch -- [lindex $::argv $i] {
			"--build_dir" { set build_dir [file normalize [lindex $::argv [incr i]]] }
			default       { error "Unknown option '[lindex $::argv $i]'" }
		}
	}
}

set ip_root "$build_dir/ip_repo/mclp_core"
set pkg_dir "$build_dir/ip_pkg"
file delete -force $ip_root $pkg_dir

create_project -force ip_pkg $pkg_dir -part $part
add_files -norecurse [glob -directory $origin_dir/rtl *.sv]
add_files -norecurse [glob -directory $origin_dir/coeff *.mem]
set_property top mclp_core [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $ip_root -vendor mclp -library ip -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property -dict [list \
	display_name  {MCLP load-cell core} \
	description   {AD7190 front end, decimation, per-cell gain/offset/trim, sum, FIR, weight, stability, weigh-in-motion, raw capture} \
	version       2.0 \
	core_revision 1 \
] $core
# AMD families with the XPM macros the core uses
if {[catch {set_property supported_families {zynq Production artix7 Production kintex7 Production virtex7 Production
		spartan7 Production zynquplus Production kintexu Production kintexuplus Production virtexu Production
		virtexuplus Production} $core} err]} {
	puts "WARNING: supported_families not set ($err); the core keeps the packager's default"
}

proc busif {name} { ipx::get_bus_interfaces $name -of_objects [ipx::current_core] }

# Interfaces: s_axi and m_axis_raw come from the port names; clocks, reset and interrupt by hand where the
# packager did not infer them
foreach {port vlnv} {
	aclk    xilinx.com:signal:clock_rtl:1.0
	clk_spi xilinx.com:signal:clock_rtl:1.0
	clk_dsp xilinx.com:signal:clock_rtl:1.0
	aresetn xilinx.com:signal:reset_rtl:1.0
	irq     xilinx.com:signal:interrupt_rtl:1.0
} {
	if {[busif $port] eq ""} { ipx::infer_bus_interface $port $vlnv $core }
}
foreach b {s_axi m_axis_raw aclk clk_spi clk_dsp aresetn irq} {
	if {[busif $b] eq ""} { error "package_ip.tcl: no bus interface $b" }
}
ipx::associate_bus_interfaces -busif s_axi -clock aclk $core
ipx::associate_bus_interfaces -busif m_axis_raw -clock aclk $core
ipx::associate_bus_interfaces -clock aclk -reset aresetn $core

proc bus_param {busif name value} {
	set p [ipx::get_bus_parameters $name -of_objects [busif $busif]]
	if {$p eq ""} { set p [ipx::add_bus_parameter $name [busif $busif]] }
	set_property value $value $p
}
bus_param aresetn POLARITY    ACTIVE_LOW
bus_param irq     SENSITIVITY LEVEL_HIGH

# Register window: 64 KB, address block reg0 (the block design assigns it at 0x43C0_0000)
set mm [ipx::get_memory_maps s_axi -of_objects $core]
if {$mm eq ""} {
	set mm [ipx::add_memory_map s_axi $core]
	set_property slave_memory_map_ref s_axi [busif s_axi]
}
set blk [ipx::get_address_blocks reg0 -of_objects $mm]
if {$blk eq ""} { set blk [ipx::add_address_block reg0 $mm] }
set_property -dict {range 65536 width 32 usage register} $blk

# N_CH: 1 to 64 AD7190 chips; spi_sdi is N_CH bits wide
set_property -dict [list \
	display_name                  {Channels (AD7190 chips, one per load cell)} \
	value                         8 \
	value_validation_type         range_long \
	value_validation_range_minimum 1 \
	value_validation_range_maximum 64 \
] [ipx::get_user_parameters N_CH -of_objects $core]

# USE_NN: 1 includes the inference engine and its model memories, 0 leaves them out
set_property -dict [list \
	display_name                  {Inference engine} \
	value                         1 \
	value_validation_type         list \
	value_validation_list         {0 1} \
] [ipx::get_user_parameters USE_NN -of_objects $core]

# The RAM images must travel with the core: XPM MEMORY_INIT_FILE finds them by name
foreach grp [ipx::get_file_groups -of_objects $core] {
	puts "[get_property NAME $grp]: [lsort [get_property NAME [ipx::get_files -of_objects $grp]]]"
}

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
close_project
puts "Packaged mclp:ip:mclp_core:2.0 in $ip_root"
