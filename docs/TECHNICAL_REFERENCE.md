# Tang Nano 9K HDMI Technical Reference

Complete technical specification for DVI 1.0 / HDMI 1.0 implementation on Tang Nano 9K (Gowin GW1NR-9C FPGA).

---

## Table of Contents
1. [Hardware Platform](#hardware-platform)
2. [Clock Architecture](#clock-architecture)
3. [Gowin IP Cores](#gowin-ip-cores)
4. [Pin Assignments](#pin-assignments)
5. [Video Timing](#video-timing)
6. [TMDS Encoding](#tmds-encoding)
7. [Critical Design Patterns](#critical-design-patterns)
8. [Timing Constraints](#timing-constraints)
9. [Performance Metrics](#performance-metrics)
10. [Build & Programming](#build--programming)

---

## Hardware Platform

### Tang Nano 9K (GW1NR-9C) Specifications

**FPGA Device**: Gowin GW1NR-9C (GW1NR-LV9QN88PC6/I5)

| Resource | Specification |
|----------|---------------|
| **Logic Elements** | 8,640 LUTs, 6,693 registers |
| **Block RAM** | 26x BSRAM (468 Kbit total) |
| **PLL** | 2x rPLL (programmable multipliers/dividers) |
| **High-Speed I/O** | 97x OSER10/ISER10 (DDR serialization) |
| **Differential I/O** | ELVDS_OBUF/IBUF primitives |
| **DSP Blocks** | 10x MULT18X18 |
| **Package** | QN88 (88-pin QFN) |

**Board Features**:
- 27 MHz crystal oscillator (Pin 52, Bank 1)
- HDMI output connector (differential pairs, Bank 1)
- 6x LEDs (Pins 10-16, Bank 3, active-low)
- Reset button (Pin 4, Bank 3, active-low)
- USB-C programming and power
- Bank voltages: Bank 1/2 = 3.3V, Bank 3 = 1.8V

---

## Clock Architecture

### Clock Tree for 640x480@60Hz Video

```
27 MHz Crystal (Pin 52)
    ↓
┌─────────────────────────┐
│ Gowin rPLL              │
│ Formula:                │
│ 27x(FBDIV+1)/(IDIV+1)   │
│ 27x(13+1)/(2+1) = 126MHz│
└─────────────────────────┘
    ↓
126 MHz TMDS Clock (5x pixel rate)
    ↓
┌─────────────────────────┐
│ Gowin CLKDIV ÷5         │
└─────────────────────────┘
    ↓
25.2 MHz Pixel Clock
```

### Clock Frequencies & Accuracy

| Clock | Target | Actual | Error | Tolerance |
|-------|--------|--------|-------|-----------|
| **Pixel Clock** | 25.175 MHz | 25.2 MHz | +0.10% | ±0.5% ✅ |
| **TMDS Clock** | 125.875 MHz | 126 MHz | +0.10% | ±0.5% ✅ |
| **Frame Rate** | 59.94 Hz | 60.05 Hz | +0.18% | ±0.5% ✅ |

**All clocks meet DVI 1.0 specification requirements.**

---

## Gowin IP Cores

### 1. Gowin rPLL (Ring PLL)

**Purpose**: Generate 126 MHz TMDS clock from 27 MHz crystal

**Configuration**:
- **Input (FCLKIN)**: 27 MHz
- **Output (CLKOUT)**: 126 MHz
- **Parameters**: IDIV_SEL=2, FBDIV_SEL=13, ODIV_SEL=4
- **Formula**: `CLKOUT = FCLKIN x (FBDIV_SEL + 1) / (IDIV_SEL + 1)`

**File**: `src/gowin_rpll/gowin_rpll.vhd`

**Important**: Always use `(FBDIV_SEL + 1)` and `(IDIV_SEL + 1)` in calculations, not the raw values.

### 2. Gowin CLKDIV

**Purpose**: Divide 126 MHz TMDS clock to 25.2 MHz pixel clock

**Configuration**:
- **Input (HCLKIN)**: 126 MHz
- **Output (CLKOUT)**: 25.2 MHz
- **DIV_MODE**: "5" (÷5 division)

**File**: `src/gowin_clkdiv/gowin_clkdiv.vhd`

### 3. Gowin OSER10 (Output Serializer)

**Purpose**: 10:1 DDR serialization for TMDS data streams

**Configuration**:
- **Parallel Input**: 10 bits @ 25.2 MHz (PCLK domain)
- **Serial Output**: 1 bit @ 126 MHz DDR (FCLK domain)
- **Effective Data Rate**: 252 Mbps DDR = 1.26 Gbps per channel
- **Instances Required**: 4 (Red, Green, Blue, Clock)

**Implementation**: Gowin built-in OSER10 primitive (Gowin-specific, no generic equivalent), instantiated directly within `hdmi_encoder.vhd`.

### 4. Gowin ELVDS_OBUF

**Purpose**: Convert single-ended to LVDS differential pairs

**Configuration**:
- **Input**: Single-ended serial TMDS data
- **Output**: Differential pair (O = positive, OB = negative auto-inverted)
- **I/O Standard**: LVCMOS33D (3.3V LVDS)
- **Instances Required**: 4 (Red, Green, Blue, Clock)

**Important**: ELVDS_OBUF automatically sets I/O type. Do NOT manually specify IO_TYPE in constraints.

---

## Pin Assignments

### HDMI Differential Pairs (Bank 1, 3.3V)

| Signal | Positive Pin | Negative Pin | FPGA Site | Channel |
|--------|--------------|--------------|-----------|---------|
| **TMDS Clock** | 69 | 68 | IOT42A/B | Clock |
| **TMDS Data 2** | 75 | 74 | IOT38A/B | Red |
| **TMDS Data 1** | 73 | 72 | IOT39A/B | Green |
| **TMDS Data 0** | 71 | 70 | IOT41A/B | Blue |

### Control Signals

| Signal | Pin | Bank | Voltage | Type | Function |
|--------|-----|------|---------|------|----------|
| **clk_27mhz** | 52 | 1 | 3.3V | LVCMOS33 | Crystal input |
| **reset_n** | 4 | 3 | 1.8V | LVCMOS18 | Active-low reset |

### Bank Voltage Configuration

- **Bank 1**: 3.3V (27 MHz clock input + HDMI differential pairs)
- **Bank 2**: 3.3V (Available for expansion I/O)
- **Bank 3**: 1.8V (LEDs + Reset button)

**Critical**: All HDMI pins must be in Bank 1 with 3.3V for proper LVDS operation.

---

## Video Timing

### 640x480@60Hz (CEA-861-B VIC 1)

#### Horizontal Timing

| Parameter | Value | Description |
|-----------|-------|-------------|
| **Active pixels** | 640 | Visible horizontal resolution |
| **Front porch** | 16 | Blank after active, before sync |
| **Sync pulse** | 96 | Horizontal sync width |
| **Back porch** | 48 | Blank after sync, before active |
| **Total (frame_width)** | 800 | Total horizontal pixels |
| **Sync polarity** | Negative | Active-low |

#### Vertical Timing

| Parameter | Value | Description |
|-----------|-------|-------------|
| **Active lines** | 480 | Visible vertical resolution |
| **Front porch** | 10 | Blank after active, before sync |
| **Sync pulse** | 2 | Vertical sync width |
| **Back porch** | 33 | Blank after sync, before active |
| **Total (frame_height)** | 525 | Total vertical lines |
| **Sync polarity** | Negative | Active-low |

#### Position Counters

- **cx**: Horizontal pixel counter (0 to 799)
- **cy**: Vertical line counter (0 to 524)
- **Reset**: cx wraps at 800, cy wraps at 525
- **Data Enable**: `de = '1' when (cx < 640) AND (cy < 480)`

---

## TMDS Encoding

### Encoding Modes

| Mode | Binary | Region | Encoding Type |
|------|--------|--------|---------------|
| **Video Data** | 001 | Active video | 8b/10b with disparity |
| **Control** | 010 | Sync signals | CTL symbols |

### Serialization (Tang Nano 9K)

**OSER10 Configuration**:
- **Input**: 10-bit TMDS word @ 25.2 MHz
- **Output**: Serial stream @ 126 MHz DDR
- **Data Rate**: 1.26 Gbps per channel (3x data channels + 1x clock)
- **Method**: DDR (data on both rising and falling edges)

**Differential Output**:
- Single-ended TMDS → ELVDS_OBUF → LVDS differential pairs
- Bank 1, 3.3V I/O standard (LVCMOS33D)
- Impedance: 100Ω differential (handled by FPGA)

---

## Critical Design Patterns

### ✅ Pattern 1: HDMI as Timing Master (REQUIRED)

```
hdmi_encoder.vhd (Timing Master):
  ├── Generates cx/cy position counters internally
  ├── Outputs cx/cy to test pattern generator
  └── Ensures perfect synchronization

test_pattern_gen.vhd (Timing Consumer):
  ├── Receives cx/cy as inputs from HDMI
  └── Generates video patterns based on position
```

**Why Required**:
- Position counters drive the video timing
- This is the standard DVI/HDMI IP core architecture

### ❌ Pattern 2: External Timing (FAILED)

```
test_pattern_gen.vhd:
  ├── Generates cx/cy internally
  └── Sends to hdmi.vhd as inputs

hdmi.vhd:
  ├── Receives external cx/cy

Result: ❌ No video (timing misalignment)
```

**Why Failed**: External timing introduces subtle synchronization issues.

---

## Timing Constraints

### SDC File (`src/TN9K_HDMI_VIDEO.sdc`)

#### Primary Clock
```sdc
create_clock -name clk_crystal -period 37.037 -waveform {0 18.518} [get_ports {clk_27mhz}]
```

#### Generated Clocks
```sdc
# Gowin automatically infers clocks from rPLL and CLKDIV primitives.
```

#### False Paths
```sdc
# Asynchronous reset
set_false_path -from [get_ports {reset_n}]

# HDMI outputs (serializers handle timing internally)
set_false_path -to [get_ports {tmds_p[*]}]
set_false_path -to [get_ports {tmds_n[*]}]
set_false_path -to [get_ports {tmds_clock_p}]
set_false_path -to [get_ports {tmds_clock_n}]
```

**Critical**: Gowin SDC does NOT support line continuation (`\`). Write commands on single lines.

---

## Performance Metrics

### Resource Utilization (GW1NR-9C)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| **Logic (LUTs)** | ~570 | 8,640 | ~7% |
| **Registers** | ~300 | 6,693 | ~5% |
| **OSER10** | 4 | 97 | 4% |
| **rPLL** | 1 | 2 | 50% |
| **CLKDIV** | 1 | 8 | 13% |

### Build Performance

- **Synthesis**: ~1 second
- **Place & Route**: ~1 second
- **Total Build**: ~3 seconds

### Timing Closure

- ✅ All timing constraints met
- ✅ No setup/hold violations

---

## Build & Programming

### Build Commands

```bash
# Clean build (recommended when changing constraints)
rm -rf impl/
"C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" build.tcl
```

### Programming Commands

```bash
# Flash to SRAM (temporary - lost on power cycle)
"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" \
  --device GW1NR-9C --run 2 \
  --fsFile "impl\pnr\TN9K_HDMI_Video.fs"

# Flash to embedded flash (permanent)
"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" \
  --device GW1NR-9C --run 5 \
  --fsFile "impl\pnr\TN9K_HDMI_Video.fs"
```

### Expected Output

After programming:
- Display shows 640x480 @ 60Hz video
- 8 test patterns rotating every 5 seconds

---

## Known Limitations

### Current Implementation
1. Single resolution: 640x480@60Hz (expandable to 720p/1080p with faster clocks)
2. Built-in test patterns only (no external video input)

### Tang Nano 9K Hardware
1. **PLL Speed**: Max ~500 MHz limits maximum resolution
2. **rPLL Availability**: 1 of 2 used, 1 remaining for higher resolutions
3. **OSER10 Headroom**: 4 of 97 used - massive headroom available
4. **Bank 1 Pins**: 9 of 25 used, 16 remaining for expansion

---

## Lessons Learned

### 🔑 Key Success Factor #1: Internal Timing
**The HDMI module MUST be the timing master.** Position counters (cx/cy) must be generated internally and output to other modules. External timing breaks packet alignment.

### 🔑 Key Success Factor #2: Gowin-Specific Implementation
- Generic serializers don't work - MUST use Gowin OSER10 primitives
- SDC syntax differs: NO line continuation (`\`)
- PLL formula is Gowin-specific: `(FBDIV_SEL + 1) / (IDIV_SEL + 1)`

### 🔑 Key Success Factor #3: Explicit Type Conversions
**Always use explicit type conversions in VHDL comparisons.** Synthesis tools may optimize away implicit conversions:
- BAD: `if h_count = CONSTANT then` (unsigned vs integer)
- GOOD: `if h_count = to_unsigned(CONSTANT, 11) then`
- **Lesson**: Type safety prevents synthesis from removing critical logic