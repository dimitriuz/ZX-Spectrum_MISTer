#!/usr/bin/env python3
"""Generate a minimal Scorpion (z80 hw=10) snapshot for the snapscorp sim test.

Emits a libspectrum v3 .z80 shaped exactly to what rtl/snap_loader.sv's z80 state
machine latches:
  - 87-byte header (30 base + 55 additional; bytes 30-31 = 55 -> hdrlen = 32+55)
  - base-header PC bytes 6-7 = 0 (v2/v3 marker), real PC at bytes 32-33 = #C000
  - hardware mode (byte 34) = 10, #7FFD field (byte 35) = 0x05,
    #1FFD field (byte 86) = 0x10
    -> after load: page_reg[2:0]=5, scorp_1ffd[4]=1, scorp_page={1,5}=13
  - one UNCOMPRESSED memory block (size marker 0xFFFF -> 16384 raw bytes) on
    Scorpion page 16 = SDRAM bank 13 (bank = page - 3), the bank #C000 decodes to
    under the restored paging. Pattern: byte i = (i*7+1) & 0xFF.

Also writes a flat $readmemh hex of the same bytes for sim/tb_top.sv. Both outputs
are regenerable artifacts (gitignored): refresh with  python3 tools/make_test_z80.py
"""
import argparse, os

HW_SCORP = 10        # LIBSPECTRUM_MACHINE_SCORP (ZS-256)
PC = 0xC000
REG_7FFD = 0x05      # -> page_reg[2:0] = 5
REG_1FFD = 0x10      # -> scorp_1ffd[4] = 1 (upper bank bit)
SCORP_PAGE = 16      # z80 page number for SDRAM bank 13 (bank = page - 3)


def pattern(i):
    return (i * 7 + 1) & 0xFF


def build():
    hdr = bytearray(87)
    # base 30-byte header (v1 layout; PC at 6-7 must be 0 for v2/v3 files)
    hdr[0] = 0x01            # A
    # 1 F, 2-3 BC, 4-5 HL, 6-7 PC=0, 8-9 SP, 10 I, 11 R: zero
    hdr[12] = 0x00           # flags: border 0 (bits 4-5 unused in v2/v3)
    # 13-26 DE/BC'/DE'/HL'/A'/F'/IY/IX: zero
    hdr[27] = 0x00           # interrupt flip-flop (DI)
    hdr[28] = 0x00           # IFF2
    hdr[29] = 0x00           # IM0
    # additional header (v3): length 55 so byte 86 (#1FFD) is inside the header
    hdr[30], hdr[31] = 55, 0
    hdr[32], hdr[33] = PC & 0xFF, PC >> 8
    hdr[34] = HW_SCORP
    hdr[35] = REG_7FFD
    hdr[36] = 0xFF           # IF1 rom paged flag (unused by the loader)
    hdr[37] = 0x00           # no modify-hardware bit
    # 38 AY port, 39-54 AY regs, 55-57 T-state counters, 58 Spectator: zero
    # 59-62 rom flags, 63-82 joystick maps/keys, 83-85 MGT/disciple: zero
    hdr[86] = REG_1FFD
    block = bytes([0xFF, 0xFF, SCORP_PAGE]) + bytes(pattern(i) for i in range(0x4000))
    return bytes(hdr) + block


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default="sim/roms/test_scorp.z80")
    ap.add_argument("--hex", dest="hexout", default=None,
                    help="flat $readmemh hex output (default: <out without extension>.hex)")
    a = ap.parse_args()
    data = build()
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "wb") as f:
        f.write(data)
    hexout = a.hexout or os.path.splitext(a.out)[0] + ".hex"
    with open(hexout, "w") as f:
        for b in data:
            f.write(f"{b:02x}\n")
    print(f"wrote {a.out} ({len(data)} bytes): hw={HW_SCORP} PC=#C000 "
          f"#7FFD=0x{REG_7FFD:02X} #1FFD=0x{REG_1FFD:02X} page{SCORP_PAGE} block 16K")
    print(f"wrote {hexout}")


main()
