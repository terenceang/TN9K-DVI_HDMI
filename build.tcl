# Build script for Tang Nano 9K HDMI (Video Only)
# Project: TN9K_HDMI_VIDEO

set_device -name GW1NR-9C GW1NR-LV9QN88C6/I5

# Add VHDL source files (in dependency order)
# Clock generation
add_file src/gowin_rpll/gowin_rpll.vhd
add_file src/gowin_clkdiv/gowin_clkdiv.vhd
add_file src/tn9k_clock_generator.vhd

# TMDS encoding
add_file src/tmds_encoder.vhd

# HDMI encoder
add_file src/hdmi_encoder.vhd

# Test pattern
add_file src/test_pattern_gen.vhd

# Top level
add_file src/tn9k_hdmi_video_top.vhd

# Add constraints
add_file src/tangnano9k.cst
add_file src/TN9K_HDMI_VIDEO.sdc

# Set top module
set_option -top_module tn9k_hdmi_video_top

# Set output directory
set_option -output_base_name TN9K_HDMI_Video

# Run synthesis
run syn

# Run place and route
run pnr
