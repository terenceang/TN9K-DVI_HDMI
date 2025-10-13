#!/usr/bin/env python3
"""
HDMI Waveform Analyzer with BCH Polynomial Testing
Analyzes CSV waveform data from Gowin logic analyzer and tests BCH polynomials
"""

import csv
import re
from collections import defaultdict
from typing import Dict, List, Tuple, Optional
import sys
import argparse


class WaveformAnalyzer:
    # HDMI Packet Type definitions
    PACKET_TYPES = {
        0x00: "Null Packet",
        0x01: "Audio Clock Regeneration (ACR)",
        0x02: "Audio Sample Packet",
        0x03: "General Control Packet",
        0x04: "AVI InfoFrame",
        0x05: "Source Product Description InfoFrame",
        0x06: "Audio InfoFrame",
        0x07: "MPEG Source InfoFrame",
        0x0A: "Gamut Metadata Packet",
        0x0D: "Vendor-Specific InfoFrame"
    }

    def __init__(self, csv_file: str):
        self.csv_file = csv_file
        self.time_unit = None
        self.headers = []
        self.data = []
        self.signals = {}
        self.bus_signals = {}
        self.data_islands = []  # Store extracted data island info

    def parse_csv(self):
        """Parse the CSV file and extract waveform data"""
        with open(self.csv_file, 'r') as f:
            lines = f.readlines()

        # Find the data header line (contains "time unit:")
        data_start = 0
        for i, line in enumerate(lines):
            if 'time unit:' in line:
                data_start = i
                break

        # Parse headers
        header_line = lines[data_start].strip()
        self.headers = [h.strip() for h in header_line.split(',')]

        # Extract time unit
        time_match = re.search(r'time unit:\s*(\w+)', header_line)
        if time_match:
            self.time_unit = time_match.group(1)

        # Parse data rows
        reader = csv.reader(lines[data_start + 1:])
        for row in reader:
            if len(row) > 1:
                self.data.append(row)

        print(f"[+] Loaded {len(self.data)} samples")
        print(f"[+] Time unit: {self.time_unit}")
        print(f"[+] Total signals: {len(self.headers) - 1}")

    def reconstruct_buses(self):
        """Reconstruct multi-bit bus signals from individual bits"""
        # Find bus patterns in headers (e.g., "signal[2:0]" or "signal[2]")
        bus_pattern = re.compile(r'(.+)\[(\d+)\]')

        bus_info = defaultdict(list)
        for idx, header in enumerate(self.headers):
            match = bus_pattern.search(header)
            if match:
                bus_name = match.group(1)
                bit_num = int(match.group(2))
                bus_info[bus_name].append((bit_num, idx))

        # Reconstruct bus values for each time step
        for bus_name, bits in bus_info.items():
            bits.sort(reverse=True)  # MSB first
            self.bus_signals[bus_name] = []

            for row in self.data:
                bus_value = 0
                has_x = False
                for bit_num, col_idx in bits:
                    if col_idx < len(row):
                        bit_val = row[col_idx].strip()
                        if bit_val == 'X':
                            has_x = True
                            break
                        elif bit_val == '1':
                            bus_value |= (1 << bit_num)

                if has_x:
                    self.bus_signals[bus_name].append(None)
                else:
                    self.bus_signals[bus_name].append(bus_value)

        print(f"[+] Reconstructed {len(self.bus_signals)} bus signals")
        for bus in self.bus_signals.keys():
            print(f"  - {bus}")

    def get_signal_column(self, signal_name: str) -> int:
        """Find column index for a signal"""
        for idx, header in enumerate(self.headers):
            if signal_name in header:
                return idx
        return -1

    def find_transitions(self, signal_name: str, from_val: str = None, to_val: str = None) -> List[Tuple[int, str, str]]:
        """Find all transitions of a signal"""
        col_idx = self.get_signal_column(signal_name)
        if col_idx < 0:
            print(f"[-] Signal '{signal_name}' not found")
            return []

        transitions = []
        prev_val = None

        for row in self.data:
            time = int(row[0])
            val = row[col_idx].strip() if col_idx < len(row) else 'X'

            if prev_val is not None and val != prev_val:
                if (from_val is None or prev_val == from_val) and (to_val is None or val == to_val):
                    transitions.append((time, prev_val, val))

            prev_val = val

        return transitions

    def find_state_changes(self) -> List[Tuple[int, int, int]]:
        """Find all state machine changes"""
        # Try both possible signal names
        state_signal = None
        if 'u_hdmi/u_audio_controller/state' in self.bus_signals:
            state_signal = 'u_hdmi/u_audio_controller/state'
        elif 'u_hdmi/debug_state' in self.bus_signals:
            state_signal = 'u_hdmi/debug_state'

        if state_signal is None:
            print("[-] State signal not found")
            return []

        state_values = self.bus_signals[state_signal]
        changes = []
        prev_state = None

        for idx, state in enumerate(state_values):
            if state is not None and state != prev_state and prev_state is not None:
                time = int(self.data[idx][0])
                changes.append((time, prev_state, state))
            prev_state = state

        return changes

    def analyze_data_islands(self):
        """Analyze data island occurrences"""
        # Try both possible signal names
        col_idx = self.get_signal_column('u_hdmi/data_island_enable')
        if col_idx < 0:
            col_idx = self.get_signal_column('debug_data_island')
        if col_idx < 0:
            print("[-] debug_data_island signal not found")
            return

        print("\n" + "="*60)
        print("DATA ISLAND ANALYSIS")
        print("="*60)

        in_island = False
        island_start = 0
        island_count = 0
        island_durations = []

        for row in self.data:
            time = int(row[0])
            val = row[col_idx].strip() if col_idx < len(row) else '0'

            if val == '1' and not in_island:
                in_island = True
                island_start = time
            elif val == '0' and in_island:
                duration = time - island_start
                island_durations.append(duration)
                island_count += 1
                in_island = False

        if island_durations:
            print(f"\nTotal data islands: {island_count}")
            print(f"Average duration: {sum(island_durations) / len(island_durations):.1f} {self.time_unit}")
            print(f"Min duration: {min(island_durations)} {self.time_unit}")
            print(f"Max duration: {max(island_durations)} {self.time_unit}")
        else:
            print("\n[!] No data islands detected")

    def analyze_timing(self):
        """Analyze horizontal and vertical timing"""
        # Try both possible signal names
        h_count_signal = None
        if 'u_pattern/h_count' in self.bus_signals:
            h_count_signal = 'u_pattern/h_count'
        elif 'u_hdmi/debug_h_count' in self.bus_signals:
            h_count_signal = 'u_hdmi/debug_h_count'

        if h_count_signal is None:
            print("[-] Horizontal counter not found")
            return

        print("\n" + "="*60)
        print("TIMING ANALYSIS")
        print("="*60)

        h_counts = self.bus_signals[h_count_signal]
        v_count_signal = 'u_pattern/v_count' if 'u_pattern/v_count' in self.bus_signals else 'u_hdmi/debug_v_count'
        v_counts = self.bus_signals.get(v_count_signal, [])

        # Standard 640x480@60Hz timing parameters
        H_ACTIVE = 640
        H_TOTAL = 800
        V_ACTIVE = 480
        V_TOTAL = 525

        # Get capture range
        h_min = min([h for h in h_counts if h is not None])
        h_max = max([h for h in h_counts if h is not None])
        v_min = min([v for v in v_counts if v is not None]) if v_counts else 0
        v_max = max([v for v in v_counts if v is not None]) if v_counts else 0

        print(f"\nCapture Range:")
        print(f"  H_COUNT: {h_min} to {h_max} (of {H_TOTAL} total)")
        print(f"  V_COUNT: {v_min} to {v_max} (of {V_TOTAL} total)")

        # Determine frame position
        print(f"\nFrame Position Analysis:")

        # Horizontal position
        if h_min < H_ACTIVE:
            if h_max < H_ACTIVE:
                h_region = "Active Video"
            else:
                h_region = "Active Video + Horizontal Blanking"
        else:
            h_region = "Horizontal Blanking"
        print(f"  Horizontal: {h_region}")

        # Vertical position
        if v_counts:
            if v_min < V_ACTIVE:
                if v_max < V_ACTIVE:
                    v_region = "Active Video"
                else:
                    v_region = "Active Video + Vertical Blanking"
            else:
                v_region = "Vertical Blanking"
            print(f"  Vertical: {v_region}")

            # Identify specific lines
            print(f"\n  Line Information:")
            if v_min == v_max:
                print(f"    Single line: {v_min}")
            else:
                print(f"    Multiple lines: {v_min} to {v_max}")
                print(f"    Total lines captured: {v_max - v_min + 1}")

        # Calculate percentage of frame captured
        h_pixels_captured = h_max - h_min + 1
        total_pixels_per_line = H_TOTAL
        h_percentage = (h_pixels_captured / total_pixels_per_line) * 100

        print(f"\n  Capture Coverage:")
        print(f"    Horizontal: {h_pixels_captured}/{H_TOTAL} pixels ({h_percentage:.1f}%)")

        if v_counts and v_max > v_min:
            v_lines_captured = v_max - v_min + 1
            v_percentage = (v_lines_captured / V_TOTAL) * 100
            total_captured = h_pixels_captured * v_lines_captured
            frame_size = H_TOTAL * V_TOTAL
            frame_percentage = (total_captured / frame_size) * 100
            print(f"    Vertical: {v_lines_captured}/{V_TOTAL} lines ({v_percentage:.1f}%)")
            print(f"    Total frame: {total_captured}/{frame_size} pixels ({frame_percentage:.2f}%)")

        # Find h_count resets (horizontal lines)
        h_resets = []
        for i in range(1, len(h_counts)):
            if h_counts[i] is not None and h_counts[i-1] is not None:
                if h_counts[i] < h_counts[i-1]:  # Counter wrapped
                    h_resets.append((int(self.data[i][0]), h_counts[i-1]))

        if h_resets:
            print(f"\n  Horizontal line transitions: {len(h_resets)}")
            h_max_values = [val for _, val in h_resets]
            if h_max_values:
                detected_h_total = max(h_max_values) + 1
                print(f"  Detected H_TOTAL: {detected_h_total}")
                if detected_h_total != H_TOTAL:
                    print(f"    [!] Warning: Expected {H_TOTAL}, got {detected_h_total}")

        # Find v_count resets (frames)
        if v_counts:
            v_resets = []
            for i in range(1, len(v_counts)):
                if v_counts[i] is not None and v_counts[i-1] is not None:
                    if v_counts[i] < v_counts[i-1]:  # Counter wrapped
                        v_resets.append((int(self.data[i][0]), v_counts[i-1]))

            if v_resets:
                print(f"\n  Frame transitions: {len(v_resets)}")
                v_max_values = [val for _, val in v_resets]
                if v_max_values:
                    detected_v_total = max(v_max_values) + 1
                    print(f"  Detected V_TOTAL: {detected_v_total}")
                    if detected_v_total != V_TOTAL:
                        print(f"    [!] Warning: Expected {V_TOTAL}, got {detected_v_total}")

        # Identify data island timing windows
        print(f"\n  Data Island Timing Context:")
        print(f"    Data islands should occur in blanking periods")
        if h_min >= H_ACTIVE:
            print(f"    [+] Capture includes horizontal blanking (good for data islands)")
        else:
            print(f"    [-] Capture is in active video region")

        if v_counts and v_min >= V_ACTIVE:
            print(f"    [+] Capture includes vertical blanking (good for data islands)")
        elif v_counts and v_max >= V_ACTIVE:
            print(f"    [+] Capture spans into vertical blanking")

        # Visual timeline
        self.print_capture_timeline(h_min, h_max, v_min, v_max, H_ACTIVE, H_TOTAL, V_ACTIVE, V_TOTAL)

    def print_capture_timeline(self, h_min, h_max, v_min, v_max, H_ACTIVE, H_TOTAL, V_ACTIVE, V_TOTAL):
        """Print a visual timeline of the capture position"""
        print(f"\n  Visual Timeline:")
        print(f"  Horizontal (one line):")

        # Create horizontal timeline
        timeline_width = 60
        h_scale = timeline_width / H_TOTAL
        active_width = int(H_ACTIVE * h_scale)
        total_width = timeline_width

        # Build the timeline
        timeline = [' '] * total_width
        for i in range(total_width):
            h_pos = int(i / h_scale)
            if h_min <= h_pos <= h_max:
                timeline[i] = '#'
            elif h_pos < H_ACTIVE:
                timeline[i] = '.'
            else:
                timeline[i] = '-'

        timeline_str = ''.join(timeline)
        print(f"    [{''.join(timeline)}]")
        print(f"     ^{' '*(active_width-1)}^{' '*(total_width-active_width-1)}^")
        print(f"     0{' '*(active_width-2)}{H_ACTIVE}{' '*(total_width-active_width-len(str(H_ACTIVE))-1)}{H_TOTAL}")
        print(f"     Active Video{'.'*10}|{'Blanking':->20}")
        print(f"     Capture: h={h_min} to h={h_max} (# = captured)")

        # Vertical timeline if available
        if v_max > v_min:
            print(f"\n  Vertical (frame):")
            v_scale = timeline_width / V_TOTAL
            v_active_width = int(V_ACTIVE * v_scale)

            v_timeline = [' '] * total_width
            for i in range(total_width):
                v_pos = int(i / v_scale)
                if v_min <= v_pos <= v_max:
                    v_timeline[i] = '#'
                elif v_pos < V_ACTIVE:
                    v_timeline[i] = '.'
                else:
                    v_timeline[i] = '-'

            print(f"    [{''.join(v_timeline)}]")
            print(f"     ^{' '*(v_active_width-1)}^{' '*(total_width-v_active_width-1)}^")
            print(f"     0{' '*(v_active_width-2)}{V_ACTIVE}{' '*(total_width-v_active_width-len(str(V_ACTIVE))-1)}{V_TOTAL}")
            print(f"     Active Lines{'.'*10}|{'V-Blank':->20}")
            print(f"     Capture: line {v_min} to line {v_max} (# = captured)")

    def analyze_state_machine(self):
        """Analyze state machine transitions"""
        changes = self.find_state_changes()

        print("\n" + "="*60)
        print("STATE MACHINE ANALYSIS")
        print("="*60)

        if not changes:
            print("\n[!] No state changes detected")
            return

        print(f"\nTotal state changes: {len(changes)}")
        print("\nFirst 20 state transitions:")
        print(f"{'Time':>10} | {'From':>6} | {'To':>6}")
        print("-" * 30)

        for time, from_state, to_state in changes[:20]:
            print(f"{time:>10} | {from_state:>6} | {to_state:>6}")

        # Count state transition types
        transition_counts = defaultdict(int)
        for _, from_state, to_state in changes:
            transition_counts[(from_state, to_state)] += 1

        print("\nState transition summary:")
        print(f"{'From':>6} -> {'To':<6} | Count")
        print("-" * 30)
        for (from_state, to_state), count in sorted(transition_counts.items()):
            print(f"{from_state:>6} -> {to_state:<6} | {count}")

    def check_sync_signals(self):
        """Check hsync and vsync behavior"""
        print("\n" + "="*60)
        print("SYNC SIGNAL ANALYSIS")
        print("="*60)

        hsync_transitions = self.find_transitions('hsync')
        vsync_transitions = self.find_transitions('vsync')

        print(f"\nHSync transitions: {len(hsync_transitions)}")
        print(f"VSync transitions: {len(vsync_transitions)}")

        # Find hsync pulses (1→0 transitions)
        hsync_pulses = [t for t, fr, to in hsync_transitions if fr == '1' and to == '0']
        if len(hsync_pulses) > 1:
            intervals = [hsync_pulses[i+1] - hsync_pulses[i] for i in range(len(hsync_pulses)-1)]
            if intervals:
                print(f"\nHSync pulse interval:")
                print(f"  Average: {sum(intervals) / len(intervals):.1f} {self.time_unit}")
                print(f"  Min: {min(intervals)} {self.time_unit}")
                print(f"  Max: {max(intervals)} {self.time_unit}")

    def extract_data_islands(self):
        """Extract data island periods and their TERC4 data"""
        # Try both possible signal names
        col_idx = self.get_signal_column('u_hdmi/data_island_enable')
        if col_idx < 0:
            col_idx = self.get_signal_column('debug_data_island')
        if col_idx < 0:
            print("[-] debug_data_island signal not found")
            return

        # Check if TERC4 signals exist (try both naming conventions)
        terc4_ch0_name = 'u_hdmi/terc4_ch0' if 'u_hdmi/terc4_ch0' in self.bus_signals else 'u_hdmi/debug_terc4_ch0'
        terc4_ch1_name = 'u_hdmi/terc4_ch1' if 'u_hdmi/terc4_ch1' in self.bus_signals else 'u_hdmi/debug_terc4_ch1'
        terc4_ch2_name = 'u_hdmi/terc4_ch2' if 'u_hdmi/terc4_ch2' in self.bus_signals else 'u_hdmi/debug_terc4_ch2'

        if terc4_ch0_name not in self.bus_signals:
            print("[-] TERC4 signals not found")
            return

        terc4_ch0 = self.bus_signals[terc4_ch0_name]
        terc4_ch1 = self.bus_signals[terc4_ch1_name]
        terc4_ch2 = self.bus_signals[terc4_ch2_name]

        self.data_islands = []
        in_island = False
        island_data = []

        for idx, row in enumerate(self.data):
            time = int(row[0])
            val = row[col_idx].strip() if col_idx < len(row) else '0'

            if val == '1':
                if not in_island:
                    in_island = True
                    island_data = []
                # Collect TERC4 data during data island
                island_data.append({
                    'time': time,
                    'ch0': terc4_ch0[idx],
                    'ch1': terc4_ch1[idx],
                    'ch2': terc4_ch2[idx]
                })
            elif val == '0' and in_island:
                # End of data island
                self.data_islands.append(island_data)
                in_island = False
                island_data = []

        print(f"[+] Extracted {len(self.data_islands)} data islands with TERC4 data")

    def calculate_bch_ecc(self, hb0: int, hb1: int, hb2: int) -> int:
        """Calculate BCH ECC for HDMI packet header

        HDMI uses BCH(31,24) code with generator polynomial: G(x) = x^7 + x^3 + x^2 + 1
        The ECC protects the 24-bit header (HB0, HB1, HB2)
        Returns: 7-bit ECC (MSB is always 0 per HDMI spec, so returns 8-bit with MSB=0)
        """
        # Combine header bytes into 24-bit value {HB0, HB1, HB2}
        data = (hb0 << 16) | (hb1 << 8) | hb2

        # BCH(31,24) generator polynomial: G(x) = x^7 + x^3 + x^2 + 1 (0x8D with implied x^7)
        poly = 0x8D  # Represents: x^7 + x^3 + x^2 + 1
        degree = 7

        # LFSR-based BCH encoder
        lfsr = 0

        # Process 24 data bits (MSB first)
        for i in range(23, -1, -1):
            bit = (data >> i) & 1
            feedback = bit ^ ((lfsr >> (degree - 1)) & 1)

            # Shift LFSR
            lfsr = (lfsr << 1) & ((1 << degree) - 1)

            # Apply polynomial taps (x^3, x^2, x^0)
            if feedback:
                lfsr ^= 0x0D  # Bits 3, 2, 0 (0b00001101)

        # HDMI ECC format: MSB=0, bits 6:0 = BCH parity
        return lfsr & 0x7F

    def test_bch_polynomial(self, hb0: int, hb1: int, hb2: int, poly: int, degree: int = 7) -> int:
        """Test a specific BCH polynomial against header data

        Args:
            hb0, hb1, hb2: Header bytes
            poly: Generator polynomial (with implied MSB term)
            degree: Polynomial degree (default 7 for BCH(31,24))

        Returns: Calculated ECC byte
        """
        # Combine header bytes into 24-bit value {HB0, HB1, HB2}
        data = (hb0 << 16) | (hb1 << 8) | hb2

        # LFSR-based BCH encoder
        lfsr = 0

        # Process 24 data bits (MSB first)
        for i in range(23, -1, -1):
            bit = (data >> i) & 1
            feedback = bit ^ ((lfsr >> (degree - 1)) & 1)

            # Shift LFSR
            lfsr = (lfsr << 1) & ((1 << degree) - 1)

            # Apply polynomial taps (excluding MSB)
            for j in range(degree - 1):
                if poly & (1 << j):
                    lfsr ^= (feedback << j)

        return lfsr & 0x7F

    def test_bch_polynomials_against_waveform(self):
        """Test multiple BCH polynomials against captured packet headers"""
        if not self.data_islands:
            self.extract_data_islands()

        if not self.data_islands:
            print("\n[!] No data islands to analyze")
            return

        # Common BCH(31,24) generator polynomials
        polynomials = [
            ("x^7 + x + 1", 0b10000011),
            ("x^7 + x^3 + x^2 + 1", 0b10001101),
            ("x^7 + x^6 + 1", 0b11000001),
            ("x^7 + x^6 + x^5 + x^4 + x^2 + x + 1", 0b11110111),
            ("x^7 + x^6 + x^3 + x + 1", 0b11001011),
            ("x^7 + x^4 + x^3 + x^2 + 1", 0b10011101),
            ("x^7 + x^5 + x^4 + x^3 + x^2 + x + 1", 0b10111111),
            ("x^7 + x^3 + 1", 0b10001001),
            ("x^7 + x^4 + 1", 0b10010001),
            ("x^7 + x^5 + x^3 + x^2 + 1", 0b10101101),
        ]

        print("\n" + "="*70)
        print("BCH POLYNOMIAL TEST AGAINST WAVEFORM DATA")
        print("="*70)

        # Test against first valid packet with full header
        test_packet = None
        for island in self.data_islands:
            if len(island) >= 18:  # Need preamble + guard + header + ECC
                # Find header start (skip preamble and guard)
                header_start = 10  # Typically at pixel 10
                if header_start + 8 <= len(island):
                    test_packet = island[header_start:]
                    break

        if not test_packet:
            print("\n[!] No valid packets found for testing")
            return

        # Decode the packet header
        packet_type, packet_name, hb0, hb1, hb2, ecc_received = self.decode_packet_header(test_packet)

        print(f"\nTest Packet:")
        print(f"  Type: {packet_name}")
        print(f"  Header: HB0=0x{hb0:02X}, HB1=0x{hb1:02X}, HB2=0x{hb2:02X}")
        print(f"  ECC from waveform: 0x{ecc_received:02X}")
        print()
        print(f"Testing {len(polynomials)} BCH polynomials:")
        print("="*70)

        best_match = None
        best_errors = 8

        for name, poly in polynomials:
            ecc_calc = self.test_bch_polynomial(hb0, hb1, hb2, poly)
            errors = bin(ecc_received ^ ecc_calc).count('1')

            match_str = ""
            if errors == 0:
                match_str = " *** PERFECT MATCH!"
                if best_match is None or errors < best_errors:
                    best_match = (name, poly, ecc_calc)
                    best_errors = errors
            elif errors < 3:
                match_str = f" (close: {errors} bit errors)"

            print(f"{name:45s} Poly=0x{poly:02X} -> 0x{ecc_calc:02X}{match_str}")

        print("="*70)
        if best_match:
            name, poly, ecc_calc = best_match
            print(f"\n[+] Best Match: {name}")
            print(f"    Polynomial: 0x{poly:02X}")
            print(f"    Calculated ECC: 0x{ecc_calc:02X}")
            print(f"    Received ECC: 0x{ecc_received:02X}")
            print(f"    Bit Errors: {best_errors}")
        else:
            print(f"\n[!] No perfect matches found")
            print(f"    The correct polynomial may not be in the common list")
            print(f"    Or there may be byte ordering differences")

    def decode_packet_header(self, island_data: List[Dict]) -> Tuple[int, str, int, int, int, int]:
        """Decode HDMI packet header from data island

        HDMI packet structure:
        - Header: 4 pixels containing HB0, HB1, HB2 bytes
        - ECC: 4 pixels containing BCH error correction code
        - Each byte is distributed across 4 pixels, with 2 bits per pixel per channel
        - Bits are transmitted LSB first across pixels
        """
        if len(island_data) < 8:
            return None, "Incomplete header", 0, 0, 0, 0

        # In HDMI packets, header bytes are spread across first 4 pixels
        # Each channel (ch0, ch1, ch2) carries 2 bits of each header byte per pixel
        # Pixel layout: bits [1:0] in pixel 0, [3:2] in pixel 1, [5:4] in pixel 2, [7:6] in pixel 3

        hb0 = 0  # Packet type (carried on ch0)
        hb1 = 0  # Packet-specific byte (carried on ch1)
        hb2 = 0  # Packet-specific byte (carried on ch2)

        # Reconstruct header bytes from pixels 0-3
        for i in range(4):
            if island_data[i]['ch0'] is not None:
                hb0 |= ((island_data[i]['ch0'] & 0x3) << (i * 2))
            if island_data[i]['ch1'] is not None:
                hb1 |= ((island_data[i]['ch1'] & 0x3) << (i * 2))
            if island_data[i]['ch2'] is not None:
                hb2 |= ((island_data[i]['ch2'] & 0x3) << (i * 2))

        # Reconstruct ECC byte from pixels 4-7
        ecc_received = 0
        for i in range(4):
            if island_data[4 + i]['ch0'] is not None:
                ecc_received |= ((island_data[4 + i]['ch0'] & 0x3) << (i * 2))

        packet_type = hb0
        packet_name = self.PACKET_TYPES.get(packet_type, f"Unknown (0x{packet_type:02X})")

        return packet_type, packet_name, hb0, hb1, hb2, ecc_received

    def analyze_terc4_packets(self):
        """Analyze TERC4 encoded packets in data islands"""
        if not self.data_islands:
            self.extract_data_islands()

        if not self.data_islands:
            print("\n[!] No data islands to analyze")
            return

        print("\n" + "="*60)
        print("TERC4 PACKET ANALYSIS")
        print("="*60)

        for idx, island in enumerate(self.data_islands):
            print(f"\n--- Data Island {idx + 1} ---")
            print(f"Duration: {len(island)} pixels")
            print(f"Time range: {island[0]['time']} - {island[-1]['time']} {self.time_unit}")

            # HDMI data island structure:
            # - Preamble: 8 pixels (constant pattern, e.g., 0x5)
            # - Leading guard band: 2 pixels (e.g., 0x3 on all channels)
            # - Packet header: 4 pixels (HB0, HB1, HB2)
            # - ECC: 4 pixels (BCH error correction code)
            # - Packet data: N pixels (sub-packets, 4 pixels each)
            # - Trailing guard band: 2 pixels

            preamble_end = 0
            guard_start = 0
            header_start = 0

            # Check for preamble pattern (typically first 8 pixels)
            if len(island) >= 8:
                first_vals = [island[i]['ch0'] for i in range(8)]
                if len(set(first_vals)) == 1:  # All same value
                    print(f"Preamble: 8 pixels of 0x{first_vals[0]:X} (pixels 0-7)")
                    preamble_end = 8

            # Check for leading guard band (typically 2 pixels after preamble)
            if preamble_end > 0 and len(island) >= preamble_end + 2:
                gb_vals = [island[preamble_end]['ch0'], island[preamble_end+1]['ch0']]
                if len(set(gb_vals)) == 1 and gb_vals[0] == 0x3:
                    print(f"Leading guard band: 2 pixels of 0x{gb_vals[0]:X} (pixels {preamble_end}-{preamble_end+1})")
                    guard_start = preamble_end
                    header_start = preamble_end + 2
                else:
                    header_start = preamble_end

            # Decode packet header with ECC
            if header_start + 8 <= len(island):
                packet_type, packet_name, hb0, hb1, hb2, ecc_received = self.decode_packet_header(island[header_start:])

                # Calculate expected ECC
                ecc_calculated = self.calculate_bch_ecc(hb0, hb1, hb2)
                ecc_valid = (ecc_received == ecc_calculated)

                print(f"Packet header (pixels {header_start}-{header_start+7}):")
                print(f"  Type: {packet_name}")
                print(f"  Header: HB0=0x{hb0:02X}, HB1=0x{hb1:02X}, HB2=0x{hb2:02X}")
                print(f"  ECC: Received=0x{ecc_received:02X}, Calculated=0x{ecc_calculated:02X}")
                if ecc_valid:
                    print(f"  [+] ECC VALID - No errors detected")
                else:
                    print(f"  [!] ECC MISMATCH - Packet may be corrupted!")
                    # Show bit differences
                    ecc_diff = ecc_received ^ ecc_calculated
                    bit_errors = bin(ecc_diff).count('1')
                    print(f"      Bit errors: {bit_errors}, Diff pattern: 0b{ecc_diff:08b}")
            else:
                print("[!] Insufficient data for packet header + ECC")
                packet_type = None

            # Show first 16 pixels of TERC4 data
            print("\nFirst 16 pixels of TERC4 data:")
            print(f"{'Pixel':>6} | {'Time':>8} | {'CH2':>4} | {'CH1':>4} | {'CH0':>4}")
            print("-" * 40)

            for i, pixel in enumerate(island[:16]):
                ch0_val = f"0x{pixel['ch0']:X}" if pixel['ch0'] is not None else "None"
                ch1_val = f"0x{pixel['ch1']:X}" if pixel['ch1'] is not None else "None"
                ch2_val = f"0x{pixel['ch2']:X}" if pixel['ch2'] is not None else "None"
                print(f"{i:>6} | {pixel['time']:>8} | {ch2_val:>4} | {ch1_val:>4} | {ch0_val:>4}")

            # Special handling for audio packets
            if packet_type == 0x02:
                self.decode_audio_sample_packet(island)
            elif packet_type == 0x01:
                self.decode_acr_packet(island)

    def decode_audio_sample_packet(self, island_data: List[Dict]):
        """Decode Audio Sample Packet structure

        Audio Sample Packet contains:
        - Header with sample information (HB1, HB2)
        - Sub-packets with PCM samples (up to 4 samples per packet)
        """
        print("\n  Audio Sample Packet Details:")

        if len(island_data) < 12:
            print("  [!] Packet too short for audio sample")
            return

        # Skip header (4 pixels) and ECC (4 pixels) = 8 pixels
        data_start = 8

        # Calculate number of sub-packets
        available_pixels = len(island_data) - data_start
        num_subpackets = available_pixels // 4

        print(f"  Total pixels: {len(island_data)}")
        print(f"  Number of sub-packets: {num_subpackets}")

        # Decode audio samples from sub-packets
        print(f"\n  Audio Samples:")

        for sp_idx in range(min(num_subpackets, 4)):  # Up to 4 sub-packets
            sp_bytes = self.decode_subpacket(island_data, data_start + (sp_idx * 4))

            if len(sp_bytes) >= 7:
                # Audio sample packet sub-packet structure:
                # SB0: Sample Present flags
                # SB1-SB3: Left channel sample (24-bit)
                # SB4-SB6: Right channel sample (24-bit)

                sample_present = sp_bytes[0]

                # Extract left channel (24-bit, little-endian)
                left_sample = sp_bytes[1] | (sp_bytes[2] << 8) | (sp_bytes[3] << 16)
                # Sign extend from 24-bit to 32-bit
                if left_sample & 0x800000:
                    left_sample |= 0xFF000000

                # Extract right channel (24-bit, little-endian)
                right_sample = sp_bytes[4] | (sp_bytes[5] << 8) | (sp_bytes[6] << 16)
                # Sign extend from 24-bit to 32-bit
                if right_sample & 0x800000:
                    right_sample |= 0xFF000000

                print(f"  Sample {sp_idx}:")
                print(f"    Present flags: 0x{sample_present:02X}")
                print(f"    Left:  {left_sample:8d} (0x{left_sample & 0xFFFFFF:06X})")
                print(f"    Right: {right_sample:8d} (0x{right_sample & 0xFFFFFF:06X})")

                # Convert to 16-bit for easier interpretation
                left_16 = (left_sample >> 8) & 0xFFFF
                right_16 = (right_sample >> 8) & 0xFFFF
                if left_16 & 0x8000:
                    left_16 = left_16 - 65536
                if right_16 & 0x8000:
                    right_16 = right_16 - 65536
                print(f"    (16-bit: L={left_16:6d}, R={right_16:6d})")

    def decode_subpacket(self, island_data: List[Dict], start_pixel: int) -> List[int]:
        """Decode a 4-pixel sub-packet into 7 data bytes

        HDMI sub-packet structure (4 pixels):
        - Each pixel has 3 channels (ch0, ch1, ch2) with 4 bits each
        - Lower 2 bits of each channel contain data
        - Returns 7 bytes of decoded data
        """
        if start_pixel + 4 > len(island_data):
            return []

        bytes_decoded = []

        # Each sub-packet contains 7 bytes distributed across channels and pixels
        # Byte layout across 4 pixels:
        # Pixel 0: SB0[1:0] on ch0[1:0], SB1[1:0] on ch1[1:0], SB2[1:0] on ch2[1:0]
        # Pixel 1: SB0[3:2] on ch0[1:0], SB1[3:2] on ch1[1:0], SB2[3:2] on ch2[1:0]
        # Pixel 2: SB0[5:4] on ch0[1:0], SB1[5:4] on ch1[1:0], SB2[5:4] on ch2[1:0]
        # Pixel 3: SB0[7:6] on ch0[1:0], SB1[7:6] on ch1[1:0], SB2[7:6] on ch2[1:0]
        # And so on for SB3-SB6

        # Simplified: Extract bytes from channel data
        for byte_idx in range(7):
            byte_val = 0
            channel = byte_idx % 3  # ch0, ch1, ch2 rotation

            for pixel in range(4):
                pixel_data = island_data[start_pixel + pixel]
                if channel == 0 and pixel_data['ch0'] is not None:
                    byte_val |= ((pixel_data['ch0'] & 0x3) << (pixel * 2))
                elif channel == 1 and pixel_data['ch1'] is not None:
                    byte_val |= ((pixel_data['ch1'] & 0x3) << (pixel * 2))
                elif channel == 2 and pixel_data['ch2'] is not None:
                    byte_val |= ((pixel_data['ch2'] & 0x3) << (pixel * 2))

            bytes_decoded.append(byte_val)

        return bytes_decoded

    def decode_acr_packet(self, island_data: List[Dict]):
        """Decode Audio Clock Regeneration packet

        ACR packet contains:
        - Sub-packet 0: CTS (Cycle Time Stamp) - 20 bits
        - Sub-packet 1: N value - 20 bits
        - Sub-packet 2-3: Reserved (0x00)
        """
        print("\n  ACR Packet Details:")

        # ACR needs header (8 pixels) + at least 2 sub-packets (8 pixels)
        if len(island_data) < 16:
            print("  [!] Packet too short for ACR (need 16+ pixels)")
            return

        # Skip header (4 pixels) and ECC (4 pixels) = 8 pixels
        data_start = 8

        # Decode sub-packet 0 (CTS value)
        if data_start + 4 <= len(island_data):
            cts_bytes = self.decode_subpacket(island_data, data_start)
            if len(cts_bytes) >= 3:
                # CTS is 20 bits: CTS[7:0], CTS[15:8], CTS[19:16] in lower 4 bits of SB2
                cts = cts_bytes[0] | (cts_bytes[1] << 8) | ((cts_bytes[2] & 0x0F) << 16)
                print(f"  CTS (Cycle Time Stamp): {cts} (0x{cts:05X})")

        # Decode sub-packet 1 (N value)
        if data_start + 8 <= len(island_data):
            n_bytes = self.decode_subpacket(island_data, data_start + 4)
            if len(n_bytes) >= 3:
                # N is 20 bits: N[7:0], N[15:8], N[19:16] in lower 4 bits of SB2
                n = n_bytes[0] | (n_bytes[1] << 8) | ((n_bytes[2] & 0x0F) << 16)
                print(f"  N value: {n} (0x{n:05X})")

                # Calculate audio sample rate from N value (for reference)
                # Common N values: 6144 (48kHz), 6272 (44.1kHz), 12288 (96kHz)
                if n == 6144:
                    print(f"    -> Audio sample rate: 48 kHz")
                elif n == 6272:
                    print(f"    -> Audio sample rate: 44.1 kHz")
                elif n == 12288:
                    print(f"    -> Audio sample rate: 96 kHz")
                elif n > 0:
                    # Approximate: fs = 128 * f_TMDS / N (for 25.2 MHz pixel clock)
                    print(f"    -> Custom N value")

        print(f"\n  ACR Synchronization Info:")
        print(f"    CTS/N ratio determines audio clock recovery")
        print(f"    HDMI receiver uses: Audio_Clock = (N/CTS) × TMDS_Clock")

    def search_pattern(self, signal_name: str, value: str, count: int = 10):
        """Search for specific signal values"""
        col_idx = self.get_signal_column(signal_name)
        if col_idx < 0:
            print(f"[-] Signal '{signal_name}' not found")
            return

        print(f"\nSearching for {signal_name} = {value} (first {count} occurrences):")
        print(f"{'Time':>10} | Value")
        print("-" * 25)

        found = 0
        for row in self.data:
            if col_idx < len(row):
                val = row[col_idx].strip()
                if val == value:
                    time = int(row[0])
                    print(f"{time:>10} | {val}")
                    found += 1
                    if found >= count:
                        break

        if found == 0:
            print(f"[!] No occurrences of {signal_name} = {value} found")

    def export_summary(self, output_file: str = None):
        """Export analysis summary to file"""
        if output_file is None:
            output_file = self.csv_file.replace('.csv', '_analysis.txt')

        # Redirect print to file
        original_stdout = sys.stdout
        with open(output_file, 'w') as f:
            sys.stdout = f

            print("HDMI WAVEFORM ANALYSIS REPORT")
            print("="*60)
            print(f"Source: {self.csv_file}")
            print(f"Samples: {len(self.data)}")
            print(f"Duration: {self.data[-1][0]} {self.time_unit}")

            self.analyze_data_islands()
            self.analyze_timing()
            self.analyze_state_machine()
            self.check_sync_signals()
            self.analyze_terc4_packets()

        sys.stdout = original_stdout
        print(f"\n[+] Summary exported to: {output_file}")

    def get_frame_position_summary(self) -> str:
        """Get a quick summary of what frame position is captured"""
        # Try both possible signal names
        h_count_signal = 'u_pattern/h_count' if 'u_pattern/h_count' in self.bus_signals else 'u_hdmi/debug_h_count'
        if h_count_signal not in self.bus_signals:
            return "Unknown (no timing data)"

        h_counts = self.bus_signals[h_count_signal]
        v_count_signal = 'u_pattern/v_count' if 'u_pattern/v_count' in self.bus_signals else 'u_hdmi/debug_v_count'
        v_counts = self.bus_signals.get(v_count_signal, [])

        H_ACTIVE = 640
        V_ACTIVE = 480

        h_min = min([h for h in h_counts if h is not None])
        h_max = max([h for h in h_counts if h is not None])
        v_min = min([v for v in v_counts if v is not None]) if v_counts else 0
        v_max = max([v for v in v_counts if v is not None]) if v_counts else 0

        # Build position string
        if h_min < H_ACTIVE and h_max < H_ACTIVE:
            h_pos = f"Active Video (h={h_min}-{h_max})"
        elif h_min >= H_ACTIVE:
            h_pos = f"H-Blanking (h={h_min}-{h_max})"
        else:
            h_pos = f"Active+Blanking (h={h_min}-{h_max})"

        if v_counts:
            if v_min < V_ACTIVE and v_max < V_ACTIVE:
                v_pos = f"Active Lines (v={v_min}-{v_max})"
            elif v_min >= V_ACTIVE:
                v_pos = f"V-Blanking (v={v_min}-{v_max})"
            else:
                v_pos = f"Active+V-Blank (v={v_min}-{v_max})"
            return f"{h_pos}, {v_pos}"
        else:
            return h_pos

    def run_full_analysis(self):
        """Run complete analysis pipeline"""
        print("\n" + "="*60)
        print("HDMI WAVEFORM ANALYZER")
        print("="*60)
        print(f"File: {self.csv_file}\n")

        self.parse_csv()
        self.reconstruct_buses()

        # Show frame position summary immediately
        frame_pos = self.get_frame_position_summary()
        print(f"\n[CAPTURE POSITION] {frame_pos}")
        print(f"[NOTE] GAO limited memory - this is a partial frame capture")

        self.analyze_data_islands()
        self.analyze_timing()
        self.analyze_state_machine()
        self.check_sync_signals()
        self.analyze_terc4_packets()

        print("\n" + "="*60)
        print("ANALYSIS COMPLETE")
        print("="*60)


def main():
    parser = argparse.ArgumentParser(
        description='HDMI Waveform Analyzer with BCH Polynomial Testing',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run full waveform analysis (default)
  python analyze_waveform.py

  # Test BCH polynomials against captured packets
  python analyze_waveform.py --test-bch

  # Run both analysis and BCH testing
  python analyze_waveform.py --test-bch --analyze

  # Specify custom CSV file
  python analyze_waveform.py --file path/to/waveform.csv
        """)

    parser.add_argument('--file', '-f',
                        default=r"E:\OneDrive\Desktop\FPGA\TN9K+DVI_HDMI\impl\wave\HDMI_Compliance_Check_core0.csv",
                        help='Path to CSV waveform file (default: HDMI_Compliance_Check_core0.csv)')
    parser.add_argument('--test-bch', '-t',
                        action='store_true',
                        help='Test BCH polynomials against waveform data')
    parser.add_argument('--analyze', '-a',
                        action='store_true',
                        help='Run full waveform analysis (default if no options specified)')
    parser.add_argument('--export', '-e',
                        action='store_true',
                        help='Export analysis to text file')

    args = parser.parse_args()

    # If no specific mode is selected, default to analysis
    if not args.test_bch and not args.analyze:
        args.analyze = True

    csv_file = args.file
    analyzer = WaveformAnalyzer(csv_file)

    try:
        # Parse and reconstruct buses (needed for both modes)
        analyzer.parse_csv()
        analyzer.reconstruct_buses()

        # Run BCH polynomial testing if requested
        if args.test_bch:
            analyzer.extract_data_islands()
            analyzer.test_bch_polynomials_against_waveform()

        # Run full analysis if requested
        if args.analyze:
            if args.test_bch:
                # Already parsed, just run the rest
                print("\n" + "="*60)
                print("HDMI WAVEFORM ANALYZER")
                print("="*60)
                print(f"File: {csv_file}\n")

            frame_pos = analyzer.get_frame_position_summary()
            print(f"\n[CAPTURE POSITION] {frame_pos}")
            print(f"[NOTE] GAO limited memory - this is a partial frame capture")

            analyzer.analyze_data_islands()
            analyzer.analyze_timing()
            analyzer.analyze_state_machine()
            analyzer.check_sync_signals()
            analyzer.analyze_terc4_packets()

            print("\n" + "="*60)
            print("ANALYSIS COMPLETE")
            print("="*60)

        # Export if requested
        if args.export:
            analyzer.export_summary()

    except FileNotFoundError:
        print(f"[-] Error: File not found: {csv_file}")
        print(f"[-] Please check the path and try again")
        sys.exit(1)
    except Exception as e:
        print(f"[-] Error: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
