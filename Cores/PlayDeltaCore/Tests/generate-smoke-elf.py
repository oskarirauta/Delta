#!/usr/bin/env python3
"""Generate an original PS2 ELF that draws a red rectangle, without an SDK/BIOS/ROM.

The program configures the GS display, submits a packed GIF A+D packet, writes
0x12345678 to EE RAM at 0x00100400, and loops. This is a frontend smoke test,
not a commercial-game compatibility or performance test.
"""
import argparse
from pathlib import Path
import struct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
args = parser.parse_args()
base = 0x00100000
code = []

def emit(*instructions):
    code.extend(instructions)

# SetGsCrt(interlace=0, mode=NTSC, field=0).
emit(0x24030002, 0x24040000, 0x24050002, 0x24060000, 0x0000000c)
# t0 = GS privileged register base, t2 = constants.
emit(0x3c081200, 0x3c0a0010, 0x354a0200)
for constant, register in [(0, 0x00), (8, 0x70), (16, 0x80)]:
    emit(0xdd490000 | constant, 0xfd090000 | register) # ld t1, offset(t2); sd t1, GS(t0)
# t0 = GIF FIFO; t2 = packet; t3 = number of quadwords.
emit(0x3c081000, 0x35086000, 0x3c0a0010, 0x354a0300, 0x240b0009)
# lq t1,0(t2); sq t1,0(t0); advance and loop.
emit(0x79490000, 0x7d090000, 0x254a0010, 0x256bffff, 0x1560fffb, 0)
# Store a marker for a debugger/test harness, then loop.
emit(0x3c080010, 0x3c091234, 0x35295678, 0xad090400, 0x1000ffff, 0)
program = bytearray(struct.pack('<%dI' % len(code), *code))
program.extend(bytes(0x200 - len(program)))
program.extend(struct.pack('<3Q', 1, 10 << 9, (639 << 32) | (447 << 44)))
program.extend(bytes(0x300 - len(program)))
registers = [
    (10 << 16, 0x4c),                            # FRAME_1: 640 pixels, RGBA32
    (0, 0x18),                                  # XYOFFSET_1
    ((639 << 16) | (447 << 48), 0x40),            # SCISSOR_1
    (0, 0x47),                                  # TEST_1
    (6, 0),                                     # PRIM: sprite
    (0x3f800000800000ff, 1),                     # RGBAQ: red, Q=1
    (0, 5),                                     # XYZ2: top-left
    ((640 * 16) | ((448 * 16) << 16), 5),        # XYZ2: bottom-right
]
program.extend(struct.pack('<2Q', len(registers) | (1 << 15) | (1 << 60), 0x0e))
for value, register in registers:
    program.extend(struct.pack('<2Q', value, register))
program.extend(bytes(max(0, 0x404 - len(program))))
ident = b'\x7fELF' + bytes([1, 1, 1]) + bytes(9)
header = ident + struct.pack('<HHIIIIIHHHHHH', 2, 8, 1, base, 52, 0, 0x20924001, 52, 32, 1, 0, 0, 0)
segment = struct.pack('<8I', 1, 0x1000, base, base, len(program), len(program), 7, 0x1000)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_bytes((header + segment).ljust(0x1000, b'\0') + program)
