# HDMI Packet ECC Analysis

## Date: October 16, 2025

## Issue: Missing BCH ECC in HDMI Packets

### HDMI Packet Structure (Per HDMI 1.4a Specification)

Every HDMI data island packet has the following structure when transmitted:

```
HDMI Packet Format (as transmitted on TMDS):
==================================================
Subpacket 0: [HB0] [HB1] [HB2] [BCH_ECC]  ← Packet Header + ECC
Subpacket 1: [PB0] [PB1] [PB2] [PB3] [PB4] [PB5] [PB6]
Subpacket 2: [PB7] [PB8] [PB9] [PB10] [PB11] [PB12] [PB13]
Subpacket 3: [PB14] [PB15] [PB16] [PB17] [PB18] [PB19] [PB20]
           + [PB21] [PB22] [PB23] [PB24] [PB25] [PB26] [PB27]
```

### Two Different Types of Error Protection

**1. InfoFrame Checksum** (Applied to InfoFrame payload)
   - Type: Simple 8-bit checksum
   - Formula: `checksum = 256 - (sum of all InfoFrame bytes) mod 256`
   - Protects: InfoFrame header (Type, Version, Length) + Data bytes
   - Location: First data byte (PB0) of InfoFrame
   - Status: ✓ **CORRECTLY IMPLEMENTED** in your code

**2. BCH ECC** (Applied to HDMI packet header)
   - Type: BCH error correction code  
   - Formula: BCH polynomial division (x^8 + x^2 + x + 1)
   - Protects: Packet header bytes (HB0, HB1, HB2)
   - Location: 4th byte of Subpacket 0
   - Status: ✗ **MISSING** in your code

## Current Implementation Status

### InfoFrame Packets (AVI, AIF)

**What you have:**
```vhdl
-- Word 0: [Checksum] [Length] [Version] [Type]
--         ↑ InfoFrame checksum (PB0)
--         ↑ This is CORRECT for the InfoFrame data payload
```

**What's missing:**
- BCH ECC calculation for packet header
- Proper mapping between InfoFrame structure and HDMI packet structure

### Correct InfoFrame Packet Structure

An InfoFrame (like AVI or AIF) transmitted as an HDMI packet should have:

```
HDMI Packet Headers (HB0, HB1, HB2):
- HB0 = InfoFrame Type (0x82 for AVI, 0x84 for AIF)
- HB1 = InfoFrame Version  
- HB2 = InfoFrame Length

BCH ECC = calculate_bch(HB0, HB1, HB2)

Packet Data (PB0-PB27):
- PB0 = InfoFrame Checksum
- PB1-PB13 = InfoFrame Data Bytes 1-13 (for AVI)
- PB14-PB27 = 0x00 (padding)
```

## Impact on Current Code

### Audio Sample Packet (ASP)
```vhdl
-- Current:
constant HEADER_WORD : std_logic_vector(31 downto 0) := x"00000402";
--  Bits [31:24] = 0x00  ← Should be BCH ECC!
--  Bits [23:16] = 0x04  ← ?? (should be HB2)
--  Bits [15:8]  = 0x02  ← ?? (should be HB1)  
--  Bits [7:0]   = 0x02  ← HB0 = Audio Sample Packet type ✓
```

**ASP Header should be:**
- HB0 = 0x02 (Audio Sample Packet)
- HB1 = Sub-packet count or flags
- HB2 = Reserved (0x00)
- ECC = BCH(HB0, HB1, HB2)

### ACR Packet
```vhdl
-- Current:
0 => x"00" & x"00" & x"00" & ACR_HEADER_TYPE,  -- Header: Type=0x01
--   [00]   [00]   [00]   [01]
--    ↑ Should be ECC!
```

**ACR Header should be:**
- HB0 = 0x01 (ACR packet type)
- HB1 = 0x00
- HB2 = 0x00  
- ECC = BCH(0x01, 0x00, 0x00)

### InfoFrames (AVI, AIF)
Currently structured as 8 words × 32 bits, but missing BCH ECC.

## Required Changes

### Priority 1: Add BCH ECC Component ✓
Created `bch_ecc.vhd` with BCH polynomial calculation.

### Priority 2: Update Packet Headers
Need to add BCH ECC calculation to:
1. **audio_sample_packet.vhd** - ASP header
2. **acr_packet.vhd** - ACR header
3. **avi_infoframe.vhd** - AVI packet header (separate from InfoFrame checksum!)
4. **audio_infoframe.vhd** - AIF packet header (separate from InfoFrame checksum!)

### Priority 3: Verify Packet Format
Ensure proper byte ordering in 32-bit words matches HDMI transmission order.

## Important Notes

### Packet Format Confusion
There are **two levels** of structure:

**Level 1: InfoFrame Structure** (Application layer)
```
[Type] [Version] [Length] [Checksum] [Data Bytes 1-N]
   ↑        ↑        ↑         ↑
  0x82    0x02     0x0D    Calculated from Type+Version+Length+Data
```

**Level 2: HDMI Packet Structure** (Transport layer)
```
Subpacket 0: [HB0=Type] [HB1=Version] [HB2=Length] [BCH_ECC]
Subpackets 1-3: [PB0=Checksum] [PB1-PB13=Data] [PB14-PB27=Padding]
```

The InfoFrame becomes the **payload** of an HDMI packet, and the HDMI packet adds its own header with BCH ECC protection.

## Testing Impact

**Without BCH ECC:**
- Some HDMI sinks may still work (they ignore/don't check ECC)
- Strict HDMI compliance testers will FAIL
- No error detection/correction capability
- May cause issues with longer cables or noisy environments

**With BCH ECC:**
- Full HDMI specification compliance
- Better compatibility with all displays
- Error detection capability
- Professional-grade implementation

## References
- HDMI Specification 1.4a, Section 5.2.3.1 (Packet Structure)
- HDMI Specification 1.4a, Section 5.2.3.2 (BCH Error Correction)
- CEA-861-D (InfoFrame formats)

## Next Steps
1. ✓ Create BCH ECC calculator component
2. TODO: Update all packet generators to include BCH ECC
3. TODO: Verify packet byte ordering
4. TODO: Test with HDMI analyzer or strict compliance display
