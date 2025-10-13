# Gowin rPLL Calculator Guide

**Complete guide for calculating Gowin rPLL frequencies with correct formulas and constraints.**

## Correct Gowin rPLL Formulas

### Official Gowin rPLL Calculation Formulas

Based on official Gowin documentation and verified sources:

```
1. fCLKOUT = (fCLKIN × FDIV) / IDIV
2. fVCO = fCLKOUT × ODIV
3. fCLKOUTD = fCLKOUT / SDIV
```

### Parameter Mapping

**Gowin IP Generator Parameters → Formula Variables:**
- `FCLKIN` → **fCLKIN** (Input clock frequency)
- `FBDIV_SEL` → **FDIV** (Feedback divider - acts as multiplier)
- `IDIV_SEL` → **IDIV** (Input divider)
- `ODIV_SEL` → **ODIV** (Output divider)

### Simplified Formula (Most Common Usage)

```
CLKOUT = FCLKIN × (FBDIV_SEL + 1) / (IDIV_SEL + 1)
```

**⚠️ CRITICAL: The "+1" is applied to both FBDIV_SEL and IDIV_SEL parameters**

### VCO Frequency Calculation

```
VCO = CLKOUT × ODIV_SEL
VCO = (FCLKIN × (FBDIV_SEL + 1) × ODIV_SEL) / (IDIV_SEL + 1)
```

### Phase Frequency Detector (PFD)

```
PFD = FCLKIN / (IDIV_SEL + 1)
```

## Frequency Range Constraints

### Critical Operating Ranges (Must Be Met)

| Parameter | Minimum | Maximum | Units | Notes |
|-----------|---------|---------|-------|-------|
| **VCO Frequency** | 400 | 900 | MHz | Core oscillator range |
| **PFD Frequency** | 3 | 400 | MHz | Phase detector input |
| **CLKOUT Frequency** | 4.6875 | 600 | MHz | Main output clock |
| **Input Clock (FCLKIN)** | 3.125 | 800 | MHz | External clock input |

### Parameter Value Ranges

| Parameter | Range | Values | Notes |
|-----------|-------|--------|-------|
| **IDIV_SEL** | 0-63 | Integer | Actual divider = IDIV_SEL + 1 |
| **FBDIV_SEL** | 0-63 | Integer | Actual multiplier = FBDIV_SEL + 1 |
| **ODIV_SEL** | - | 2, 4, 8, 16, 32, 48, 64, 80, 96, 112, 128 | Fixed values only |

## Step-by-Step Calculation Process

### Step 1: Define Requirements
- **Input Clock**: Available crystal/oscillator frequency
- **Target Output**: Desired output clock frequency
- **Application**: HDMI, DDR, system clock, etc.

### Step 2: Calculate PFD Frequency
```
PFD = FCLKIN / (IDIV_SEL + 1)
```
**Constraint**: 3 MHz ≤ PFD ≤ 400 MHz

### Step 3: Calculate Output Clock
```
CLKOUT = FCLKIN × (FBDIV_SEL + 1) / (IDIV_SEL + 1)
```
**Constraint**: 4.6875 MHz ≤ CLKOUT ≤ 600 MHz

### Step 4: Verify VCO Frequency
```
VCO = CLKOUT × ODIV_SEL
```
**Constraint**: 400 MHz ≤ VCO ≤ 900 MHz

### Step 5: Check All Constraints
- ✅ PFD in range (3-400 MHz)
- ✅ CLKOUT in range (4.6875-600 MHz)
- ✅ VCO in range (400-900 MHz)
- ✅ All parameters within allowed values

## Practical Examples

### Example 1: HDMI TMDS Clock (27MHz → 126MHz)

**Requirements:**
- Input: 27 MHz crystal
- Target: 126 MHz (5× 25.2MHz for HDMI)

**Calculation:**
```
Target: CLKOUT = 126 MHz
Given: FCLKIN = 27 MHz

Try: IDIV_SEL = 2, FBDIV_SEL = 13, ODIV_SEL = 4

PFD = 27 / (2 + 1) = 9 MHz ✅ (3-400 MHz range)
CLKOUT = 27 × (13 + 1) / (2 + 1) = 27 × 14 / 3 = 126 MHz ✅
VCO = 126 × 4 = 504 MHz ✅ (400-900 MHz range)
```

**Result: Perfect match with all constraints satisfied**

### Example 2: System Clock (27MHz → 100MHz)

**Requirements:**
- Input: 27 MHz crystal
- Target: 100 MHz system clock

**Calculation:**
```
Target: CLKOUT = 100 MHz
Given: FCLKIN = 27 MHz

Try: IDIV_SEL = 8, FBDIV_SEL = 32, ODIV_SEL = 8

PFD = 27 / (8 + 1) = 3 MHz ✅ (3-400 MHz range)
CLKOUT = 27 × (32 + 1) / (8 + 1) = 27 × 33 / 9 = 99 MHz ≈ 100 MHz ✅
VCO = 99 × 8 = 792 MHz ✅ (400-900 MHz range)
```

**Result: 99 MHz output (1% error from target)**

### Example 3: DDR Clock (27MHz → 200MHz)

**Requirements:**
- Input: 27 MHz crystal
- Target: 200 MHz DDR clock

**Calculation:**
```
Target: CLKOUT = 200 MHz
Given: FCLKIN = 27 MHz

Try: IDIV_SEL = 2, FBDIV_SEL = 29, ODIV_SEL = 2

PFD = 27 / (2 + 1) = 9 MHz ✅ (3-400 MHz range)
CLKOUT = 27 × (29 + 1) / (2 + 1) = 27 × 30 / 3 = 270 MHz ❌ (>600 MHz max)

Try: IDIV_SEL = 5, FBDIV_SEL = 36, ODIV_SEL = 2

PFD = 27 / (5 + 1) = 4.5 MHz ✅ (3-400 MHz range)
CLKOUT = 27 × (36 + 1) / (5 + 1) = 27 × 37 / 6 = 166.5 MHz ✅
VCO = 166.5 × 2 = 333 MHz ❌ (<400 MHz min)

Try: IDIV_SEL = 5, FBDIV_SEL = 36, ODIV_SEL = 4

PFD = 27 / (5 + 1) = 4.5 MHz ✅
CLKOUT = 27 × (36 + 1) / (5 + 1) = 166.5 MHz ✅
VCO = 166.5 × 4 = 666 MHz ✅ (400-900 MHz range)
```

**Result: 166.5 MHz output (16.75% error - may need different approach)**

## Common Calculation Errors

### Error 1: Forgetting the "+1"
```
❌ WRONG: CLKOUT = FCLKIN × FBDIV_SEL / IDIV_SEL
✅ RIGHT: CLKOUT = FCLKIN × (FBDIV_SEL + 1) / (IDIV_SEL + 1)
```

### Error 2: Using Wrong VCO Formula
```
❌ WRONG: VCO = FCLKIN × (FBDIV_SEL + 1) / (IDIV_SEL + 1)
✅ RIGHT: VCO = CLKOUT × ODIV_SEL
```

### Error 3: Ignoring PFD Constraints
```
❌ WRONG: Only checking output frequency
✅ RIGHT: Verify PFD = FCLKIN / (IDIV_SEL + 1) is 3-400 MHz
```

### Error 4: Invalid ODIV_SEL Values
```
❌ WRONG: Using arbitrary values like ODIV_SEL = 3, 5, 6, 7
✅ RIGHT: Only use: 2, 4, 8, 16, 32, 48, 64, 80, 96, 112, 128
```

## Design Guidelines

### For Best Performance

1. **Keep PFD frequency high** (closer to 400 MHz) for better jitter performance
2. **Minimize IDIV_SEL** when possible to reduce phase noise
3. **Choose ODIV_SEL** to place VCO in middle of range (650 MHz typical)
4. **Verify all constraints** before implementation

### For HDMI Applications

- **Target frequencies**: 25.175 MHz (pixel), 125.875 MHz (TMDS)
- **Use proven configurations** from this guide
- **Consider clock domain crossing** between different frequencies

### For High-Speed Applications

- **Minimize jitter** by optimizing PFD frequency
- **Check VCO stability** across temperature and voltage
- **Use dedicated clock networks** for critical signals

## Verification Methods

### Simulation Verification
```vhdl
-- Check PLL lock signal
assert pll_locked = '1' report "PLL not locked" severity error;

-- Measure output frequency (simulation only)
process
    variable period : time;
    variable freq : real;
begin
    wait until rising_edge(clk_out);
    wait until rising_edge(clk_out);
    period := now - last_time;
    freq := 1.0 / (period / 1 ns) * 1.0e9;  -- Convert to Hz
    report "Measured frequency: " & real'image(freq/1.0e6) & " MHz";
end process;
```

### Hardware Verification
- **Oscilloscope measurement** of output frequency
- **PLL lock indicator** LED or signal
- **Functional testing** of downstream logic
- **Timing analysis** in synthesis tools

## Quick Reference Calculator

### Formula Summary
```
PFD = FCLKIN / (IDIV_SEL + 1)
CLKOUT = FCLKIN × (FBDIV_SEL + 1) / (IDIV_SEL + 1)
VCO = CLKOUT × ODIV_SEL
```

### Constraint Summary
```
3 MHz ≤ PFD ≤ 400 MHz
4.6875 MHz ≤ CLKOUT ≤ 600 MHz
400 MHz ≤ VCO ≤ 900 MHz
```

### Parameter Ranges
```
0 ≤ IDIV_SEL ≤ 63
0 ≤ FBDIV_SEL ≤ 63
ODIV_SEL ∈ {2, 4, 8, 16, 32, 48, 64, 80, 96, 112, 128}
```

## Online Calculator Tool

For interactive calculations, use the verified online calculator:
**https://juj.github.io/gowin_fpga_code_generators/pll_calculator.html**

This tool implements the correct formulas and automatically checks constraints.

## Common FPGA Applications

### Tang Nano 20K HDMI (This Project)
- **Input**: 27 MHz → **Output**: 126 MHz (TMDS) + 25.2 MHz (pixel)
- **Config**: IDIV_SEL=2, FBDIV_SEL=13, ODIV_SEL=4 + /5 divider

### Tang Nano 9K VGA
- **Input**: 27 MHz → **Output**: 25.175 MHz (pixel)
- **Config**: IDIV_SEL=26, FBDIV_SEL=24, ODIV_SEL=32

### System Clock Generation
- **Input**: 27 MHz → **Output**: 100 MHz (system)
- **Config**: IDIV_SEL=8, FBDIV_SEL=32, ODIV_SEL=8

---

**Note**: This guide is based on official Gowin documentation and verified implementations. Always double-check calculations and test in hardware before finalizing designs.