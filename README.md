# Tang Nano 9K HDMI Encoder

This project is a complete DVI 1.0 / HDMI 1.0 implementation in VHDL for the Gowin GW1NR-9C FPGA on the Tang Nano 9K development board. It functions as a generic, standalone video encoder that accepts 24-bit RGB video inputs and generates a compliant TMDS output.

The primary goal is to provide a clear, well-documented, and reusable HDMI/DVI video core for FPGA hobbyists and developers.

## Features

*   **Hardware:** Tang Nano 9K (Gowin GW1NR-9C)
*   **Language:** VHDL (VHDL-2008)
*   **Video Output:** 640x480@60Hz with a 24-bit RGB color depth.
*   **HDMI/DVI Compliance:** DVI 1.0 compliant, using HDMI 1.0 protocol features for video data.
*   **Modularity:** The `hdmi_encoder.vhd` module is designed to be reusable in other projects.
*   **Test Pattern:** Includes a built-in test pattern generator that produces a standard 8-bar color pattern.

## Project Configuration

This repository includes a single video-only configuration.

## Getting Started

### Prerequisites

*   **Gowin EDA:** You need the Gowin EDA (FPGA design software) installed. This project was developed with version `1.9.9 Beta-4 Education`.
*   **Tang Nano 9K:** The target hardware for this project.

### Building the Project

The build process is automated using a TCL script.

1.  **Open a Gowin Shell:** Launch the Gowin Shell (`gw_sh.exe`) from your EDA installation directory.
2.  **Navigate to the Project:** `cd` to the root of this repository.
3.  **Run the Build Script:**
    ```tcl
    source build.tcl
    ```
    This will synthesize the design and run the place-and-route tool. The final bitstream (`.fs` file) will be located in `impl/pnr/`.

### Programming the FPGA

You can program the generated bitstream to the Tang Nano 9K's SRAM (volatile) or Flash (non-volatile) using the Gowin Programmer tool.

**1. Programming to SRAM (for quick testing):**

This will load the design into the FPGA's SRAM. The configuration will be lost when the device is powered off.

```bash
"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 2 --fsFile "impl\pnr\TN9K_HDMI_Video.fs"
```

**2. Programming to Flash (for permanent storage):**

This will write the design to the onboard Flash memory. The FPGA will automatically load this configuration on power-up.

```bash
"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 5 --fsFile "impl\pnr\TN9K_HDMI_Video.fs"
```

## Technical Reference

For a detailed explanation of the HDMI protocol, TMDS encoding, and the VHDL architecture, please see the [Technical Reference](./docs/TECHNICAL_REFERENCE.md).

## Troubleshooting

If you encounter any issues, please refer to the [Troubleshooting Guide](./TROUBLESHOOTING.md).

## License

This project is open-source and available under the MIT License. See the `LICENSE` file for more details.
