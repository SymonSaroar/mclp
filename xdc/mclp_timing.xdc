# ADC SPI pins. SCLK toggles every 4 clk_spi cycles (2.5 MHz); DOUT passes a 2-FF XPM synchronizer and is
# sampled 150 ns after the SCLK falling edge. The pins have no timing relationship to a clock edge.
set_false_path -to [get_ports {spi_sclk spi_sdo spi_cs_n adc_sync_n}]
set_false_path -from [get_ports {spi_sdi[*]}]

# Clock-domain crossings use XPM macros (CDC, FIFOs, independent-clock memories), which carry their
# own constraints.
