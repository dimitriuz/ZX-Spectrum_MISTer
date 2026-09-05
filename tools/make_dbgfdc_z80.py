#!/usr/bin/env python3
"""Build DBGFDC.Z80 - shows ONLY the FDC debug registers 8-15, large.

The 16-row reader packs too tightly to read reliably off a photo. This shows
eight registers, each TWO character rows tall with a blank row between, so the
whole screen is used for 8 values. GREEN = bit set, RED = bit clear, bits 7..0.

  band 0 = reg 8  FDC port accesses
  band 1 = reg 9  last value written to #FF (drive/side/reset)
  band 2 = reg 10 last WD1793 command
  band 3 = reg 11 last WD1793 status read
  band 4 = reg 12 {ready,drive1,reset,side,intrq,drq,plusd_en,trdos_en}
  band 5 = reg 13 #FF write count
  band 6 = reg 14 {6'b0, img_mounted}
  band 7 = reg 15 sentinel - MUST read 10100101 (0xA5)
"""
import sys
ORG = 0x6000

def asm():
    lab, out, fix = {}, bytearray(), []
    def L(n): lab[n] = ORG + len(out)
    def b(*xs): out.extend(xs)
    def w(nn): out.extend((nn & 0xFF, nn >> 8))
    def jr(op, name): out.append(op); fix.append((len(out), name)); out.append(0)
    def rd():                                  # A <- port #7AF8+d ; E <- A
        b(0x7A); b(0xF6,0xF8); b(0x4F); b(0x06,0x7A); b(0xED,0x78); b(0x5F)

    b(0xF3); b(0x31); w(0x7FFE)                        # di : ld sp
    b(0x21); w(0x4000); b(0x36,0x00)
    b(0x11); w(0x4001); b(0x01); w(0x17FF); b(0xED,0xB0)   # clear pixels
    b(0x21); w(0x5800); b(0x36,0x38)
    b(0x11); w(0x5801); b(0x01); w(0x02FF); b(0xED,0xB0)   # clear attrs

    b(0x16,0x00)                                       # ld d,0  (reg 8+d)
    L('loop')
    rd()
    # HL = #5800 + d*96   (3 char rows per band)
    b(0x26,0x00); b(0x6A)                              # ld h,0 : ld l,d
    b(0x29); b(0x29); b(0x29); b(0x29); b(0x29)        # *32
    b(0x44); b(0x4D)                                   # ld b,h : ld c,l   (bc = d*32)
    b(0x29)                                            # *64
    b(0x09)                                            # add hl,bc -> *96
    b(0x01); w(0x5800); b(0x09)                        # + #5800
    b(0x06,0x08)                                       # ld b,8
    L('b1')
    b(0xCB,0x23); b(0x3E,0x20); jr(0x38,'o1'); b(0x3E,0x10)
    L('o1'); b(0x77); b(0x23)
    b(0x10,0x00); fix.append((len(out)-1,'b1'))        # djnz b1
    b(0x01); w(0x0018); b(0x09)                        # ld bc,24 : add hl,bc -> next char row
    rd()                                               # re-read (port is stable)
    b(0x06,0x08)
    L('b2')
    b(0xCB,0x23); b(0x3E,0x20); jr(0x38,'o2'); b(0x3E,0x10)
    L('o2'); b(0x77); b(0x23)
    b(0x10,0x00); fix.append((len(out)-1,'b2'))
    b(0x14); b(0x7A); b(0xFE,0x08)                     # inc d : ld a,d : cp 8
    jr(0x20,'loop')
    L('stop'); jr(0x18,'stop')

    for pos, name in fix:
        dlt = lab[name] - (ORG + pos + 1)
        assert -128 <= dlt <= 127, (name, dlt)
        out[pos] = dlt & 0xFF
    return bytes(out)

code = asm()
bank5 = bytearray(0x4000); bank5[ORG-0x4000:ORG-0x4000+len(code)] = code
h = bytearray(30); h[8:10] = (0x7FFE).to_bytes(2,'little'); h[29] = 1
ext = bytearray(55); ext[0:2] = ORG.to_bytes(2,'little'); ext[2] = 10
snap = bytes(h) + len(ext).to_bytes(2,'little') + bytes(ext) + bytes([0xFF,0xFF,8]) + bytes(bank5)
out = sys.argv[1] if len(sys.argv) > 1 else 'DBGFDC.Z80'
open(out,'wb').write(snap)
print(f"{out}: code {len(code)} bytes at #{ORG:04X}")
