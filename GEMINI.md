# Gemini Code Assistant Context

This file provides context to the Gemini Code Assistant for the Tang Nano 9K HDMI Encoder project.

## Project Overview

This project is a DVI 1.0 / HDMI 1.0 implementation in VHDL for the Gowin GW1NR-9C FPGA on the Tang Nano 9K development board. It functions as a generic, standalone video encoder that accepts 24-bit RGB video inputs and generates a compliant TMDS output.

**Key Features:**

*   **Hardware:** Tang Nano 9K (Gowin GW1NR-9C)
*   **Language:** VHDL
*   **Video Output:** 640x480@60Hz with a 24-bit RGB color depth.
*   **Modularity:** The `hdmi_encoder.vhd` module is designed to be reusable in other projects.

The project includes one main configuration for video only.

## Building and Running

The project uses TCL scripts with the Gowin EDA toolchain.

### Build Commands

There is a single build script for the project:

```bash
"C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" build.tcl
```

### Programming the FPGA

After a successful build, the generated `.fs` file can be programmed to the Tang Nano 9K's SRAM (volatile) or Flash (non-volatile).

**Programming to SRAM (for testing):**

```bash
"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 2 --fsFile "impl\pnr\TN9K_HDMI_Video.fs"
```

**Programming to Flash (for permanent storage):**

```bash
"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 5 --fsFile "impl\pnr\TN9K_HDMI_Video.fs"
```

## Development Conventions

*   **VHDL Style:** The code is written in a clear and modular style, with comprehensive comments.
*   **Generic Modules:** The core HDMI encoder module is designed to be generic and reusable.
*   **Clocking:** The project uses the onboard 27MHz crystal and a Gowin rPLL IP core to generate the required pixel and TMDS serial clocks.
*   **Constraints:** Pin constraints are defined in `src/tangnano9k.cst` and timing constraints in `src/TN9K_HDMI_VIDEO.sdc`.
*   **Build System:** The build process is automated with TCL scripts.

## Key Files

*   `README.md`: The main entry point for understanding the project.
*   `build.tcl`: The build script for the video-only version.
*   `src/tn9k_hdmi_video_top.vhd`: The top-level VHDL entity for the video configuration.
*   `src/hdmi_encoder.vhd`: The core HDMI encoder module.
*   `src/tangnano9k.cst`: The pin constraint file.
*   `src/TN9K_HDMI_VIDEO.sdc`: The timing constraint file.
*   `docs/TECHNICAL_REFERENCE.md`: A detailed technical reference for the project.
