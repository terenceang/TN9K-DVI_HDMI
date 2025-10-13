# Signal Naming Guide

## Overview

This document describes the signal naming conventions used throughout the HDMI/DVI video generator project. All signals have been renamed from abbreviated, cryptic names to clear, self-descriptive names that follow consistent patterns.

**Date**: October 13, 2025  
**Project**: Tang Nano 9K HDMI Video Generator  
**Status**: Complete - All VHDL files updated

---

## Naming Philosophy

### Core Principles

1. **Self-Documenting**: Signal names should clearly indicate their purpose without requiring comments
2. **Consistent Patterns**: Similar signals use similar naming structures
3. **Scope-Appropriate Length**: Top-level signals use full descriptive names; local signals can be shorter when context is clear
4. **No Abbreviations**: Avoid `clk`, `rst`, `sync`, `cnt` - spell out `clock`, `reset`, `synchronize`, `counter`
5. **Action/Type Suffix**: Include signal type or action where appropriate (e.g., `_counter`, `_enable`, `_register`)

### Naming Patterns

#### Clock Signals
- **Pattern**: `{function}_clock` or `clock_{detail}`
- **Examples**:
  - `pixel_clock` (25.2 MHz pixel rate clock)
  - `serial_clock_5x` (126 MHz serialization clock, 5× pixel rate)
  - `system_clock` (27 MHz input clock)

#### Reset Signals
- **Pattern**: `reset_{scope}` or `{scope}_reset`
- **Examples**:
  - `reset_synchronized` (synchronized global reset)
  - `external_reset_n` (active-low external reset)

#### Video Timing Signals
- **Pattern**: `video_{signal_name}`
- **Examples**:
  - `video_hsync` (horizontal sync pulse)
  - `video_vsync` (vertical sync pulse)
  - `video_data_enable` (data valid indicator)
  - `video_red`, `video_green`, `video_blue` (8-bit color channels)

#### Position Counters
- **Pattern**: `{dimension}_{detail}`
- **Examples**:
  - `horizontal_counter` (pixel X position)
  - `vertical_counter` (line Y position)
  - `horizontal_position` (synonym for counter in some contexts)
  - `vertical_position` (synonym for counter in some contexts)

#### TMDS Encoding Signals
- **Pattern**: `{stage}_{channel}` or `{function}_{detail}`
- **Examples**:
  - `tmds_encoded_red` (10-bit encoded red channel)
  - `tmds_encoded_green` (10-bit encoded green channel)
  - `tmds_encoded_blue` (10-bit encoded blue channel)
  - `encoded_intermediate` (9-bit stage 1 encoding result)
  - `disparity_counter` (DC balance tracking counter)

#### Control/Status Signals
- **Pattern**: `{function}_{type}`
- **Examples**:
  - `clock_pll_locked` (PLL lock status)
  - `serializer_red` (serializer output for red channel)
  - `ones_count_input` (count of '1' bits in input byte)

---

## Signal Renaming Mappings

### Top-Level Module (`tn9k_hdmi_video_top.vhd`)

| Old Name | New Name | Description |
|----------|----------|-------------|
| `clk` | `system_clock` | 27 MHz input clock |
| `reset_n` | `external_reset_n` | Active-low external reset |
| `clk_pixel` | `pixel_clock` | 25.2 MHz pixel clock |
| `clk_serial` | `serial_clock_5x` | 126 MHz serial clock |
| `pll_lock` | `clock_pll_locked` | PLL lock indicator |
| `rst_sync_n` | `reset_synchronized` | Synchronized reset |
| `hsync` | `video_hsync` | Horizontal sync |
| `vsync` | `video_vsync` | Vertical sync |
| `de` | `video_data_enable` | Data enable |
| `r`, `g`, `b` | `video_red`, `video_green`, `video_blue` | Color channels |
| `tmds_r`, `tmds_g`, `tmds_b` | `tmds_encoded_red`, `tmds_encoded_green`, `tmds_encoded_blue` | Encoded TMDS data |

**Instance Naming**:
- `u_clk_gen` → `clock_generator_inst`
- `u_pattern_gen` → `pattern_generator_inst`
- `u_hdmi_enc` → `hdmi_encoder_inst`

---

### HDMI Encoder Module (`hdmi_encoder.vhd`)

| Old Name | New Name | Description |
|----------|----------|-------------|
| `clk_pixel` | `pixel_clock` | Pixel rate clock |
| `clk_serial` | `serial_clock_5x` | Serialization clock |
| `rst_n` | `reset_n` | Active-low reset |
| `h_count` | `horizontal_position` | Horizontal pixel counter |
| `v_count` | `vertical_position` | Vertical line counter |
| `de` | `video_data_enable` | Data enable signal |
| `r`, `g`, `b` | `video_red`, `video_green`, `video_blue` | Input color channels |
| `hsync`, `vsync` | `video_hsync`, `video_vsync` | Sync signals |
| `tmds_r`, `tmds_g`, `tmds_b` | `tmds_encoded_red`, `tmds_encoded_green`, `tmds_encoded_blue` | TMDS encoded outputs |
| `ser_red`, `ser_green`, `ser_blue` | `serializer_red`, `serializer_green`, `serializer_blue` | Serialized TMDS data |

**Instance Naming**:
- `encoder_r/g/b` → `red/green/blue_channel_encoder_inst`
- `serializer_r/g/b` → `red/green/blue_channel_serializer_inst`
- `tmds_obuf_r/g/b/c` → `red/green/blue/clock_channel_output_buffer_inst`

---

### Test Pattern Generator (`test_pattern_gen.vhd`)

| Old Name | New Name | Description |
|----------|----------|-------------|
| `clk` | `pixel_clock` | Pixel rate clock |
| `reset_n` | `reset_n` | Active-low reset |
| `h_count` | `horizontal_counter` | X position counter |
| `v_count` | `vertical_counter` | Y position counter |
| `hsync_int` | `horizontal_sync` | Internal h-sync |
| `vsync_int` | `vertical_sync` | Internal v-sync |
| `de_int` | `data_enable` | Internal data enable |
| `bar_select` | `color_bar_index` | Which color bar to display (0-7) |

**Process/Constant Naming**:
- Process: `color_pattern_generator` (was unnamed)
- Constants retain descriptive names (e.g., `H_ACTIVE`, `V_ACTIVE`)

---

### TMDS Encoder Module (`tmds_encoder.vhd`)

| Old Name | New Name | Description |
|----------|----------|-------------|
| `clk` | `pixel_clock` | Pixel rate clock |
| `reset_n` | `reset_n` | Active-low reset |
| `de` | `video_data_enable` | Data enable |
| `c0`, `c1` | `control_signal_0`, `control_signal_1` | Control bits (hsync/vsync) |
| `din` | `data_input` | 8-bit input data |
| `q_m` | `encoded_intermediate` | 9-bit stage 1 result |
| `q_out` | `output_register` | 10-bit registered output |
| `cnt` | `disparity_counter` | 6-bit DC balance counter |
| `n1_d` | `ones_count_input` | Count of 1s in input |
| `dout` | `encoded_output` | Final 10-bit TMDS output |

**Variable Naming** (inside `tmds_encoding_process`):

| Old Variable Name | New Variable Name | Description |
|-------------------|-------------------|-------------|
| `q_m_temp` | `encoded_temp` | Temporary 9-bit encoding result |
| `n1_q_m_var` | `ones_count_var` | Count of 1s in encoded data |
| `n0_q_m_var` | `zeros_count_var` | Count of 0s in encoded data |
| `cnt_next` | `disparity_next` | Next disparity counter value |
| `cnt_tmp` | `disparity_temp` | Intermediate disparity value |
| `q_out_next` | `output_next` | Next output register value |

**Process Naming**:
- `tmds_encoding_process` (replaces unnamed process)

---

## Guidelines for Future Development

### Adding New Signals

When adding new signals to the project, follow these guidelines:

1. **Choose descriptive base names**:
   - ✅ `frame_counter`, `packet_valid`, `buffer_full`
   - ❌ `cnt2`, `valid`, `full`

2. **Use consistent suffixes**:
   - Counters: `_counter`
   - Enables: `_enable`
   - Registers: `_register` or `_reg` (if in very local scope)
   - Clocks: `_clock`
   - Resets: `_reset`
   - Status: `_ready`, `_valid`, `_locked`

3. **Indicate signal direction/scope**:
   - `input_` or `external_` for top-level inputs
   - `output_` for top-level outputs
   - `internal_` for signals not exposed outside module

4. **Avoid single-letter names** except in very tight loops or mathematical contexts

5. **Be consistent within a module**:
   - If you use `horizontal_counter` in one place, don't use `h_count` elsewhere

### Refactoring Existing Code

When updating legacy code:

1. **Read context first**: Understand what the signal does before renaming
2. **Rename systematically**: Update declarations, then all usages
3. **Update comments**: Ensure comments reflect new names
4. **Test after renaming**: Build and verify functionality unchanged
5. **Document changes**: Update this guide with new mappings

---

## Benefits Achieved

### Before Renaming
```vhdl
signal clk_pixel : std_logic;
signal rst_sync_n : std_logic;
signal de : std_logic;
signal tmds_r : std_logic_vector(9 downto 0);
variable cnt : signed(5 downto 0);
variable q_m_temp : std_logic_vector(8 downto 0);
```

**Issues**:
- `clk_pixel`: Which clock? System, pixel, serial?
- `rst_sync_n`: What does "sync" mean? Synchronized with what?
- `de`: What does "de" stand for?
- `tmds_r`: Is this input, output, intermediate value?
- `cnt`: Counter for what?
- `q_m_temp`: Cryptic abbreviation from DVI spec

### After Renaming
```vhdl
signal pixel_clock : std_logic;
signal reset_synchronized : std_logic;
signal video_data_enable : std_logic;
signal tmds_encoded_red : std_logic_vector(9 downto 0);
variable disparity_counter : signed(5 downto 0);
variable encoded_temp : std_logic_vector(8 downto 0);
```

**Improvements**:
- ✅ Purpose immediately clear
- ✅ No need to reference comments or spec
- ✅ Easier code review and debugging
- ✅ Reduced cognitive load
- ✅ Better IDE autocomplete

---

## Verification

All renames have been verified by:

1. **Compilation**: Gowin IDE synthesis completed without errors
2. **Resource Usage**: Unchanged from optimized baseline (122 logic, 103 registers)
3. **Timing**: All constraints met
4. **Functionality**: Build output identical to pre-rename version

**Build Status**: ✅ SUCCESS  
**Resource Usage**: 122/8640 Logic (2%), 103/6693 Registers (2%), 10/71 I/O (15%)  
**Timing**: All constraints met  
**Date Verified**: October 13, 2025

---

## References

- DVI 1.0 Specification (for TMDS encoding terminology)
- VHDL-2008 Standard (naming conventions)
- Project files: `src/*.vhd`

---

*This naming guide is part of the Tang Nano 9K HDMI Video Generator optimization project.*
