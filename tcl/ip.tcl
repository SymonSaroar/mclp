# AMD IP cores outside the block design. Sourced by mclp.tcl after create_project.
# Needs $origin_dir.

# FCLK0 100 MHz -> clk_spi 20 MHz (SCLK 2.5 MHz = /8), clk_dsp 50 MHz.
# FCLK0 already leaves the PS through a BUFG, hence No_buffer. The board flow breaks No_buffer
# generation in a board-part project (clk_wiz xdc.ttcl), so it is off.
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name clk_wiz_0
set_property -dict [list \
	CONFIG.USE_BOARD_FLOW false CONFIG.PRIM_SOURCE No_buffer CONFIG.PRIM_IN_FREQ 100.000 \
	CONFIG.CLK_OUT1_PORT clk_spi CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 20.000 \
	CONFIG.CLKOUT2_USED true CONFIG.CLK_OUT2_PORT clk_dsp CONFIG.CLKOUT2_REQUESTED_OUT_FREQ 50.000 \
	CONFIG.RESET_TYPE ACTIVE_LOW CONFIG.RESET_PORT resetn \
] [get_ips clk_wiz_0]

