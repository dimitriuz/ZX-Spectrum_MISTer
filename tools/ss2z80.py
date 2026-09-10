#!/usr/bin/env python3
"""Convert a MiSTer .ss savestate written by the ZX-Spectrum core into a .z80.

The core stores an uncompressed .z80 v3 image in the DDR slot after an 8-byte
header that Main_MiSTer writes to the file verbatim:

    offset 0  uint32  counter  (bumped by the core to trigger the save)
    offset 4  uint32  size in dwords of the payload that follows
    offset 8  payload

The dword count is itself dword-aligned, so the payload can carry up to 3
trailing padding bytes past the last real .z80 block. Stripping the 8-byte
slot header and that trailing padding yields a file Fuse 1.7 can open, which
is how the writer is checked without a Quartus rebuild.
"""
import argparse
import struct
import sys

EXPECTED_HDR_LEN = 87
VALID_HW_MODES = {0: '48K', 4: '128K', 7: '+3', 9: 'Pentagon 128', 10: 'Scorpion ZS-256'}


def parse_ss(data):
    """Return (counter, size_dwords, payload) from a raw .ss file."""
    if len(data) < 8:
        raise ValueError("file too short: need at least the 8-byte slot header")
    counter, dwords = struct.unpack_from('<II', data, 0)
    payload = data[8:8 + dwords * 4]
    if len(payload) != dwords * 4:
        raise ValueError(
            f"file too short: header claims {dwords} dwords "
            f"({dwords * 4} bytes) but only {len(data) - 8} follow")
    return counter, dwords, payload


def z80_data_end(p):
    """Return the offset in payload p where real .z80 data ends.

    Walks the header, then each FF FF <page> block (3 + 16384 bytes), and
    stops at the last complete block. Anything from this offset onward
    (e.g. the dword padding the .ss container requires) is not part of the
    .z80 image and must not be written to a .z80 file.
    """
    if len(p) < EXPECTED_HDR_LEN:
        return len(p)
    hdrlen = 32 + struct.unpack_from('<H', p, 30)[0]
    off = hdrlen
    while off + 3 <= len(p):
        length = struct.unpack_from('<H', p, off)[0]
        if length != 0xFFFF:
            break
        block_end = off + 3 + 16384
        if block_end > len(p):
            break
        off = block_end
    return off


def validate_z80(p):
    """Return a list of problems with an uncompressed .z80 v3 image. Empty == valid."""
    problems = []
    if len(p) < EXPECTED_HDR_LEN:
        problems.append(f"truncated: {len(p)} bytes, header alone needs {EXPECTED_HDR_LEN}")
        return problems

    if p[6] or p[7]:
        problems.append(
            f"offset 6-7 must be zero for v2/v3, got {p[6]:#04x} {p[7]:#04x} "
            "(snap_loader would parse this as a v1 file)")

    if p[12] == 0xFF:
        problems.append("offset 12 is 0xFF, which snap_loader special-cases as border 0")
    if p[12] & 0x20:
        problems.append("offset 12 bit 5 set: claims compressed data, writer must not compress")

    hdrlen = 32 + struct.unpack_from('<H', p, 30)[0]
    if hdrlen != EXPECTED_HDR_LEN:
        problems.append(
            f"header length {hdrlen} != {EXPECTED_HDR_LEN}; "
            "offset 30-31 must be 55 so the #1FFD byte at offset 86 is in range")

    if p[34] == 3:
        problems.append("hardware mode 3 is read as 48K at this header length; never emit it")
    elif p[34] not in VALID_HW_MODES:
        problems.append(f"hardware mode {p[34]} is not one this core round-trips")

    off = hdrlen
    while off < len(p):
        remaining = len(p) - off
        if remaining <= 3:
            # Too little left for a real block header (3 bytes + 16384 of
            # body). Up to 3 zero bytes here is legitimate dword padding
            # that the .ss container requires; anything else is a real
            # problem, checked before trying to parse a block header out of
            # these leftover bytes.
            trailing = p[off:]
            if all(b == 0 for b in trailing):
                off = len(p)
            else:
                problems.append(f"truncated block header at offset {off}")
            break
        length = struct.unpack_from('<H', p, off)[0]
        page = p[off + 2]
        if length != 0xFFFF:
            problems.append(
                f"block at offset {off} (page {page}) has length {length:#06x}, "
                "expected 0xFFFF meaning 16384 uncompressed bytes")
            break
        off += 3 + 16384
    if off > len(p):
        problems.append(f"last block runs {off - len(p)} bytes past end of file")

    return problems


def decode_z80(p):
    """Decode the header into a dict of machine state."""
    if len(p) < EXPECTED_HDR_LEN:
        raise ValueError(f"payload too short: {len(p)} bytes, need at least {EXPECTED_HDR_LEN}")
    hdrlen = 32 + struct.unpack_from('<H', p, 30)[0]
    r = p[11] | ((p[12] & 1) << 7)
    pages = []
    off = hdrlen
    while off + 3 <= len(p):
        length = struct.unpack_from('<H', p, off)[0]
        pages.append(p[off + 2])
        off += 3 + (16384 if length == 0xFFFF else length)
    return {
        'af': (p[0] << 8) | p[1],
        'bc': struct.unpack_from('<H', p, 2)[0],
        'hl': struct.unpack_from('<H', p, 4)[0],
        'sp': struct.unpack_from('<H', p, 8)[0],
        'i': p[10],
        'r': r,
        'border': (p[12] >> 1) & 7,
        'de': struct.unpack_from('<H', p, 13)[0],
        'bc_': struct.unpack_from('<H', p, 15)[0],
        'de_': struct.unpack_from('<H', p, 17)[0],
        'hl_': struct.unpack_from('<H', p, 19)[0],
        'af_': (p[21] << 8) | p[22],
        'iy': struct.unpack_from('<H', p, 23)[0],
        'ix': struct.unpack_from('<H', p, 25)[0],
        'iff1': bool(p[27]),
        'iff2': bool(p[28]),
        'im': p[29] & 3,
        'pc': struct.unpack_from('<H', p, 32)[0],
        'hw_mode': p[34],
        'port_7ffd': p[35],
        # Last OUT to #FFFD (the selected AY register) and the 16 AY
        # registers - rtl/ss_writer.sv emits these at bytes 38 and 39-54.
        'ay_sel': p[38],
        'ay_regs': list(p[39:55]),
        'port_1ffd': p[86] if hdrlen > 86 else 0,
        'pages': pages,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('input', help='.ss file written by the core')
    ap.add_argument('-o', '--output', help='write the .z80 here')
    ap.add_argument('--dump', action='store_true', help='print decoded machine state')
    args = ap.parse_args()

    with open(args.input, 'rb') as f:
        data = f.read()

    try:
        counter, dwords, payload = parse_ss(data)
    except ValueError as e:
        print(f"INVALID: {e}", file=sys.stderr)
        return 1

    print(f"slot header: counter={counter} size={dwords} dwords ({dwords * 4} bytes)")

    problems = validate_z80(payload)
    for p in problems:
        print(f"INVALID: {p}", file=sys.stderr)

    if args.dump:
        try:
            d = decode_z80(payload)
            print(f"  AF={d['af']:04X}  BC={d['bc']:04X}  DE={d['de']:04X}  HL={d['hl']:04X}")
            print(f"  AF'={d['af_']:04X} BC'={d['bc_']:04X} DE'={d['de_']:04X} HL'={d['hl_']:04X}")
            print(f"  IX={d['ix']:04X}  IY={d['iy']:04X}  SP={d['sp']:04X}  PC={d['pc']:04X}")
            print(f"  I={d['i']:02X} R={d['r']:02X} IM={d['im']} "
                  f"IFF1={d['iff1']} IFF2={d['iff2']} border={d['border']}")
            print(f"  hw={d['hw_mode']} ({VALID_HW_MODES.get(d['hw_mode'], '?')}) "
                  f"7FFD={d['port_7ffd']:02X} 1FFD={d['port_1ffd']:02X}")
            print(f"  pages: {d['pages']}")
            print(f"  AY sel={d['ay_sel']:02X} regs="
                  f"{' '.join(f'{v:02X}' for v in d['ay_regs'])}")
        except (ValueError, struct.error, IndexError) as e:
            print(f"ERROR: Cannot decode payload: {e}", file=sys.stderr)

    if args.output:
        z80_data = payload[:z80_data_end(payload)]
        with open(args.output, 'wb') as f:
            f.write(z80_data)
        print(f"wrote {len(z80_data)} bytes to {args.output}")

    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
