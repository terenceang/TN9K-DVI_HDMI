# HDMI Timing Deep Analysis

## Date: October 16, 2025

## Executive Summary

**Status**: ⚠️ **TIMING ISSUE DETECTED** - Critical mismatch between counter implementation and back porch detection.

The VGA timing fix correctly updated the counter to start at 0 for front porch, but the packet scheduler's back porch detection is now **INCORRECT** for the new timing scheme.

---

## VGA 640×480@60Hz Timing Specification

### Horizontal Timing (Standard VGA)
```
Total pixels per line: 800
Pixel clock: 25.175 MHz (typically 25.2 MHz)

Timeline (standard VGA order):
Position    0-15     16-111    112-159     160-799
Period      FP       SYNC      BP          ACTIVE
Duration    16 px    96 px     48 px       640 px
```

### Vertical Timing (Standard VGA)
```
Total lines per frame: 525
Frame rate: 60 Hz

Timeline (standard VGA order):
Line        0-9      10-11     12-34       35-514
Period      FP       SYNC      BP          ACTIVE
Duration    10 ln    2 ln      23 ln       480 ln
```

---

## Current Implementation Analysis

### 1. HDMI Encoder Counter ✅ CORRECT (After Fix)

**File**: `src/hdmi_encoder.vhd`

```vhdl
-- Counter implementation:
timing_counter: process(clk_pixel, rst_n)
begin
    if horizontal_position = H_TOTAL - 1 then  -- Rolls over at 799
        horizontal_position <= (others => '0');
    else
        horizontal_position <= horizontal_position + 1;
    end if;
end process;
```

**Counter Range**: 0 to 799 (H_TOTAL - 1)

**Timeline**:
```
h_count:    0-15      16-111    112-159     160-799
Period:     FP        SYNC      BP          ACTIVE
```

**Data Enable**: ✅ CORRECT
```vhdl
data_enable <= '1' when (horizontal_position >= 160 and horizontal_position < 800 and 
                         vertical_position >= 35 and vertical_position < 515) else '0';
```
- Active video: h_count 160-799 (640 pixels) ✅
- Active video: v_count 35-514 (480 lines) ✅

---

### 2. Test Pattern Generator ✅ CORRECT (After Fix)

**File**: `src/test_pattern_gen.vhd`

**Timing Constants**:
```vhdl
constant H_SYNC_START : integer := 16;   -- Start of HSYNC pulse
constant H_SYNC_END   : integer := 112;  -- End of HSYNC pulse (16 + 96)
constant V_SYNC_START : integer := 10;   -- Start of VSYNC pulse  
constant V_SYNC_END   : integer := 12;   -- End of VSYNC pulse (10 + 2)
constant H_VIDEO_START : integer := 160; -- Start of active video (16 + 96 + 48)
constant V_VIDEO_START : integer := 35;  -- Start of active video (10 + 2 + 23)
```

**Sync Generation**: ✅ CORRECT
```vhdl
-- HSync active during h_count 16-111 (96 pixels)
if (h_count >= H_SYNC_START) and (h_count < H_SYNC_END) then
    horizontal_sync <= '0';  -- Active low
else
    horizontal_sync <= '1';
end if;

-- VSync active during v_count 10-11 (2 lines)
if (v_count >= V_SYNC_START) and (v_count < V_SYNC_END) then
    vertical_sync <= '0';  -- Active low
else
    vertical_sync <= '1';
end if;
```

**Analysis**: Sync pulses are generated at correct positions for standard VGA timing.

---

### 3. Packet Scheduler ❌ **CRITICAL ERROR**

**File**: `src/packet_scheduler.vhd`

**Back Porch Detection** (CURRENT - INCORRECT):
```vhdl
constant H_SYNC      : integer := 96;    -- Sync pulse width
constant H_BACK      : integer := 48;    -- Back porch pixels
constant H_BACK_START : integer := H_SYNC;        -- = 96
constant H_BACK_END   : integer := H_SYNC + H_BACK; -- = 144

back_porch_detect: process(clk_pixel, rst_n)
begin
    if rst_n = '0' then
        in_back_porch <= '0';
    elsif rising_edge(clk_pixel) then
        -- Back porch window: pixel 96 to 143 (48 pixels)
        if h_count >= H_BACK_START and h_count < H_BACK_END then
            in_back_porch <= '1';
        else
            in_back_porch <= '0';
        end if;
    end if;
end process;
```

**Problem**: This assumes counter starts at 0 for SYNC start, but it actually starts at 0 for FRONT PORCH start!

**What Actually Happens**:
```
With new timing (h_count starts at 0 for FP):
Position:   0-15    16-111   112-159    160-799
Period:     FP      SYNC     BP         ACTIVE
Detection:          ❌ SYNC  ✅ BP       ❌ ACTIVE

Current code detects: h_count 96-143
- h_count 96-111 = Last 16 pixels of SYNC ❌ WRONG!
- h_count 112-143 = First 32 pixels of BP ✅ PARTIAL
- h_count 144-159 = Last 16 pixels of BP ❌ MISSED!
```

**Impact**:
- Packet scheduler detects back porch at WRONG time
- Packets may be transmitted during SYNC pulse (16 pixels overlap) ❌
- Last 16 pixels of back porch are NOT used for packets ❌
- May cause HDMI compliance issues or display artifacts

---

## Detailed Timing Verification

### Correct Back Porch Window

For standard VGA timing with counter starting at 0 for FP:

```
Back porch should be: h_count 112 to 159 (48 pixels)

Breakdown:
- FP:     h_count 0-15     (16 pixels)
- SYNC:   h_count 16-111   (96 pixels)
- BP:     h_count 112-159  (48 pixels) ← Packets go here
- ACTIVE: h_count 160-799  (640 pixels)
```

### HDMI Data Island Timing Requirements

Per HDMI specification, data islands must be transmitted during **blanking intervals only**:

1. **Allowed**: Horizontal back porch (after SYNC, before active video)
2. **Allowed**: Horizontal front porch (after active video, before SYNC)
3. **NOT allowed**: During SYNC pulse
4. **NOT allowed**: During active video

**Current implementation**: Attempting to transmit during positions 96-143
- Positions 96-111 = **SYNC pulse** ❌ VIOLATION!
- Positions 112-143 = Back porch ✅ OK
- Positions 144-159 = Back porch (missed) ❌ WASTED

---

## Packet Island Window Analysis

### Required Space for Packet Transmission

```vhdl
constant PREAMBLE_LENGTH : integer := 8;   -- 8 pixels
constant GUARD_LENGTH    : integer := 2;   -- 2 pixels each side
constant ISLAND_LENGTH   : integer := 32;  -- 32 pixels for packet data

-- Total: 8 + 2 + 32 + 2 = 44 pixels
```

### Available Space in Back Porch

**Back porch**: 48 pixels (h_count 112-159)
**Required**: 44 pixels
**Margin**: 4 pixels ✅ Sufficient (but currently only using 32 pixels!)

### Current vs Correct Detection

**CURRENT (WRONG)**:
```
Detection window: h_count 96-143 (48 pixels)
  - 96-111   = SYNC (16 px)  ❌ Transmitting during SYNC!
  - 112-143  = BP (32 px)    ✅ Only 32 pixels of BP used
  - 144-159  = BP (16 px)    ❌ Wasted, not used
Total usable: 32 pixels (not enough for 44-pixel island!)
```

**CORRECT (SHOULD BE)**:
```
Detection window: h_count 112-159 (48 pixels)
  - 112-159  = BP (48 px)    ✅ Full back porch available
Total usable: 48 pixels (enough for 44-pixel island + 4px margin) ✅
```

---

## Impact Assessment

### Critical Issues

1. **❌ HDMI Specification Violation**
   - Data islands transmitted during SYNC pulse (h_count 96-111)
   - Violates HDMI 1.4a section 5.2.3 (islands only during blanking)

2. **❌ Insufficient Island Window**
   - Only 32 pixels of back porch used
   - Need 44 pixels for complete packet transmission
   - **Packets are being truncated or corrupted!**

3. **❌ Display Compatibility**
   - May cause sync issues on strict displays
   - Possible visual artifacts during sync period
   - Audio packets may be incomplete

### Symptoms You Might See

- ✓ Video works (data enable is correct)
- ⚠️ Audio may be unreliable (packets incomplete)
- ⚠️ Some displays work, others don't (strict vs lenient sync checking)
- ⚠️ Possible horizontal sync artifacts (data during sync pulse)

---

## Required Fix

### Update Packet Scheduler Constants

**File**: `src/packet_scheduler.vhd`

**Change** (Line ~95):
```vhdl
-- OLD (WRONG):
constant H_BACK_START : integer := H_SYNC;        -- = 96
constant H_BACK_END   : integer := H_SYNC + H_BACK; -- = 144

-- NEW (CORRECT):
constant H_FRONT     : integer := 16;    -- Front porch pixels
constant H_BACK_START : integer := H_FRONT + H_SYNC;           -- = 16 + 96 = 112
constant H_BACK_END   : integer := H_FRONT + H_SYNC + H_BACK;  -- = 16 + 96 + 48 = 160
```

### Verification After Fix

```
New detection window: h_count 112-159 (48 pixels)

Timeline:
h_count:    0-15    16-111   112-159    160-799
Period:     FP      SYNC     BP         ACTIVE
Detection:  ❌ No   ❌ No    ✅ YES     ❌ No

Island window (44 pixels):
- Preamble (8px):    h_count 112-119
- Guard (2px):       h_count 120-121
- Data Island (32px): h_count 122-153
- Guard (2px):       h_count 154-155
- Margin (4px):      h_count 156-159 (safety buffer)
```

---

## Vertical Timing Analysis

### Vertical Back Porch

**Specification**:
```
v_count:    0-9      10-11    12-34      35-514
Period:     FP       SYNC     BP         ACTIVE
```

**Current Implementation**: Not explicitly used by packet scheduler (only horizontal back porch is checked)

**Status**: ✅ OK - Packet scheduler only uses horizontal blanking, which is correct.

---

## Clock Domain Analysis

### Pixel Clock (25.2 MHz)

**All signals are synchronous to pixel clock**:
- ✅ `horizontal_position` counter
- ✅ `vertical_position` counter  
- ✅ `data_enable` signal
- ✅ Sync signals (hsync, vsync)
- ✅ Packet scheduler state machine
- ✅ All packet generators

**Status**: ✅ No clock domain crossing issues

### Serial Clock (252 MHz = 10× pixel clock)

**Only used for**:
- TMDS serialization (OSER10)
- Properly synchronized to pixel clock

**Status**: ✅ Correct relationship (10:1 ratio)

---

## Summary of Findings

### ✅ Correct

1. Counter implementation (h_count, v_count)
2. Data enable generation (active video window)
3. Sync pulse generation (hsync, vsync timing)
4. Test pattern generator timing
5. Clock domain design
6. VGA timing order (FP → SYNC → BP → ACTIVE)

### ❌ Critical Error

1. **Packet scheduler back porch detection**
   - Currently: h_count 96-143 (WRONG - overlaps SYNC!)
   - Should be: h_count 112-159 (CORRECT - full BP)
   - **Impact**: Data islands transmitted during SYNC pulse
   - **Impact**: Insufficient window for complete packets (32px vs needed 44px)

### ⚠️ Potential Issues

1. Audio packets may be incomplete (insufficient transmission window)
2. HDMI specification violation (data during SYNC)
3. May fail on strict HDMI compliance displays
4. Possible sync artifacts or instability

---

## Recommended Actions

### Priority 1: Fix Packet Scheduler (CRITICAL)
Update back porch detection to use correct timing constants:
```vhdl
constant H_BACK_START : integer := 112;  -- Start of back porch
constant H_BACK_END   : integer := 160;  -- End of back porch
```

### Priority 2: Verification
After fix:
1. Rebuild and test video output
2. Test audio functionality
3. Verify with HDMI analyzer (if available)
4. Test on multiple displays (strict and lenient)

### Priority 3: Documentation
Update timing diagrams and comments to reflect corrected implementation

---

## References

- VESA DMT Standard - 640×480@60Hz timing
- HDMI Specification 1.4a, Section 5.2.3 (Data Island Timing)
- VGA timing fix documentation (October 16, 2025)
