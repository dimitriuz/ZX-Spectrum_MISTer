#!/usr/bin/env python3
"""Build DBGREAD.Z80 - reads the core's debug port #7AF0-#7AF7 and shows it.

Enable OSD > Hardware > "Debug Port #7AF0" first, then load this snapshot.

Display: 8 rows, one per register, 8 attribute cells each = bits 7..0.
GREEN cell = bit set, RED cell = bit clear. Row meanings:
  0  flags : b4=scorp_rom1 b3=scorp b2=trdos_en b1=trdos_ever b0=reached_3Dxx
  1  #7FFD at the FIRST #3Dxx fetch
  2  #1FFD at the FIRST #3Dxx fetch
  3  low address byte of that fetch
  4  count of #3Dxx fetches (saturates at 255)
  5  count of trdos_en assertions
  6  #7FFD now
  7  #1FFD now
Runs from bank 5 at #6000, same as BANKTEST.
"""
import sys
ORG = 0x6000

def asm():
    lab, out, fix = {}, bytearray(), []
    def L(n): lab[n] = ORG + len(out)
    def b(*xs): out.extend(xs)
    def w(nn): out.extend((nn & 0xFF, nn >> 8))
    def jr(op, name): out.append(op); fix.append((len(out), name, 'r')); out.append(0)

    b(0xF3)                                  # di
    b(0x31); w(0x7FFE)                       # ld sp,#7FFE
    b(0x21); w(0x4000); b(0x36,0x00)         # ld hl,#4000 : ld (hl),0
    b(0x11); w(0x4001); b(0x01); w(0x17FF); b(0xED,0xB0)   # clear pixels
    b(0x21); w(0x5800); b(0x36,0x38)         # ld hl,#5800 : ld (hl),#38
    b(0x11); w(0x5801); b(0x01); w(0x02FF); b(0xED,0xB0)   # clear attrs

    b(0x16,0x00)                             # ld d,0        d = register index
    L('rloop')
    b(0x7A)                                  # ld a,d
    b(0xF6,0xF0)                             # or #F0        -> low byte #F0+idx
    b(0x4F)                                  # ld c,a
    b(0x06,0x7A)                             # ld b,#7A      -> BC = #7Ax
    b(0xED,0x78)                             # in a,(c)
    b(0x5F)                                  # ld e,a        e = value

    # HL = #5800 + d*32   (row d)
    b(0x7A); b(0x87); b(0x87); b(0x87); b(0x87); b(0x87)    # ld a,d : a*32 (row offset)
    b(0x6F)                                  # ld l,a
    b(0x26,0x58)                             # ld h,#58    -> HL = #5800 + d*32
    b(0x06,0x08)                             # ld b,8        8 bits
    L('bloop')
    b(0xCB,0x23)                             # sla e         MSB -> carry
    b(0x3E,0x20)                             # ld a,#20      green
    jr(0x38,'setc')                          # jr c,setc
    b(0x3E,0x10)                             # ld a,#10      red
    L('setc')
    b(0x77)                                  # ld (hl),a
    b(0x23)                                  # inc hl
    b(0x10,0x00); fix.append((len(out)-1,'bloop','r'))      # djnz bloop
    b(0x14)                                  # inc d
    b(0x7A); b(0xFE,0x08)                    # ld a,d : cp 8
    jr(0x20,'rloop')                         # jr nz,rloop
    L('stop'); jr(0x18,'stop')

    for pos, name, _ in fix:
        d = lab[name] - (ORG + pos + 1)
        assert -128 <= d <= 127, (name, d)
        out[pos] = d & 0xFF
    return bytes(out)

code = asm()
bank5 = bytearray(0x4000)
bank5[ORG-0x4000: ORG-0x4000+len(code)] = code
h = bytearray(30)
h[8:10] = (0x7FFE).to_bytes(2,'little'); h[29] = 1
ext = bytearray(55)
ext[0:2] = ORG.to_bytes(2,'little'); ext[2] = 10; ext[3] = 0x00; ext[54] = 0x00
snap = bytes(h) + len(ext).to_bytes(2,'little') + bytes(ext) + bytes([0xFF,0xFF,8]) + bytes(bank5)
out = sys.argv[1] if len(sys.argv) > 1 else 'DBGREAD.Z80'
open(out,'wb').write(snap)
print(f"{out}: {len(snap)} bytes, code {len(code)} bytes at #{ORG:04X}")
