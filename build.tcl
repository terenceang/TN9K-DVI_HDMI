# Build script for Tang Nano 9K HDMI Encoder

# Set device
set_device -name GW1NR-9C GW1NR-LV9QN88C6/I5

# Open project
open_project TN9K_HDMI_VIDEO.gprj

# Ensure shared configuration package is compiled before dependent units
analyze_file -type vhdl src/hdmi_config_pkg.vhd

# Run synthesis, place & route
run all
