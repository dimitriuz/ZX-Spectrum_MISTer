#!/usr/bin/env python3
"""Build BANKTEST.Z80 - a Scorpion ZS-256 RAM paging probe as a .z80 snapshot.

Why a snapshot and not a tape: snapshot data is written straight to RAM through
ioctl, so there is no analogue tape timing to go wrong, no BASIC involved, and
the header sets #7FFD/#1FFD directly - so paging is NOT locked (bit 5 clear),
unlike 48 BASIC where only 2 of the 16 banks are reachable.

The code writes a signature into all 16 banks through #C000, reads them back,
and paints the top attribute row: two cells per bank, GREEN = bank holds its own
data, RED = wrong. Left to right = bank 0..15. Then it halts in a tight loop.

Runs from bank 5 at #6000 (bank 5 is fixed at #4000-#7FFF on the Scorpion, and
also holds the screen, so the code and its display are always mapped).
"""
import sys

CODE_ORG = 0x6000

def asm():
    lab, out, fix = {}, bytearray(), []
    def L(n): lab[n] = CODE_ORG + len(out)
    def b(*xs): out.extend(xs)
    def w(nn): out.extend((nn & 0xFF, nn >> 8))
    def jr(op, name):                      # relative jump, patched in pass 2
        out.append(op); fix.append((len(out), name)); out.append(0)

    b(0xF3)                                 # di
    b(0x31); w(0x7FFE)                      # ld sp,#7FFE
    b(0x21); w(0x4000)                      # ld hl,#4000
    b(0x36, 0x00)                           # ld (hl),0
    b(0x11); w(0x4001)                      # ld de,#4001
    b(0x01); w(0x17FF)                      # ld bc,#17FF
    b(0xED, 0xB0)                           # ldir            - clear pixels
    b(0x21); w(0x5800)                      # ld hl,#5800
    b(0x36, 0x38)                           # ld (hl),#38     - white paper
    b(0x11); w(0x5801)                      # ld de,#5801
    b(0x01); w(0x02FF)                      # ld bc,#02FF
    b(0xED, 0xB0)                           # ldir            - clear attrs

    b(0x16, 0x00)                           # ld d,0
    L('wloop')
    b(0xCD); fix.append((len(out), 'setbank@w')); w(0)   # call setbank
    b(0x7A)                                 # ld a,d
    b(0x32); w(0xC000)                      # ld (#C000),a
    b(0x2F)                                 # cpl
    b(0x32); w(0xC001)                      # ld (#C001),a
    b(0x14)                                 # inc d
    b(0x7A); b(0xFE, 0x10)                  # ld a,d : cp 16
    jr(0x20, 'wloop')                       # jr nz,wloop

    b(0x16, 0x00)                           # ld d,0
    L('rloop')
    b(0xCD); fix.append((len(out), 'setbank@r')); w(0)   # call setbank
    b(0x3A); w(0xC000)                      # ld a,(#C000)
    b(0xBA)                                 # cp d
    jr(0x20, 'bad')                         # jr nz,bad
    b(0x3A); w(0xC001)                      # ld a,(#C001)
    b(0x5F)                                 # ld e,a
    b(0x7A); b(0x2F)                        # ld a,d : cpl
    b(0xBB)                                 # cp e
    jr(0x20, 'bad')                         # jr nz,bad
    b(0x3E, 0x20)                           # ld a,#20  green paper
    jr(0x18, 'mark')                        # jr mark
    L('bad')
    b(0x3E, 0x10)                           # ld a,#10  red paper
    L('mark')
    b(0x4F)                                 # ld c,a
    b(0x7A); b(0x87)                        # ld a,d : add a,a
    b(0x6F); b(0x26, 0x58)                  # ld l,a : ld h,#58
    b(0x71); b(0x23); b(0x71)               # ld (hl),c : inc hl : ld (hl),c
    b(0x14)                                 # inc d
    b(0x7A); b(0xFE, 0x10)                  # ld a,d : cp 16
    jr(0x20, 'rloop')                       # jr nz,rloop
    L('stop'); jr(0x18, 'stop')             # jr stop

    L('setbank')
    b(0x7A); b(0xE6, 0x08); b(0x07)         # ld a,d : and 8 : rlca   -> 0 or 16
    b(0x01); w(0x1FFD); b(0xED, 0x79)       # ld bc,#1FFD : out (c),a
    b(0x7A); b(0xE6, 0x07)                  # ld a,d : and 7   (bit3=0 screen5, bit4=0, bit5=0 UNLOCKED)
    b(0x01); w(0x7FFD); b(0xED, 0x79)       # ld bc,#7FFD : out (c),a
    b(0xC9)                                 # ret

    for pos, name in fix:
        if name.startswith('setbank'):
            t = lab['setbank']; out[pos] = t & 0xFF; out[pos+1] = t >> 8
        else:
            d = lab[name] - (CODE_ORG + pos + 1)
            assert -128 <= d <= 127, (name, d)
            out[pos] = d & 0xFF
    return bytes(out)

code = asm()
bank5 = bytearray(0x4000)
bank5[CODE_ORG - 0x4000: CODE_ORG - 0x4000 + len(code)] = code

h = bytearray(30)
h[0]  = 0x00        # A
h[1]  = 0x00        # F
h[6:8] = b'\x00\x00'                 # PC = 0 -> v2/v3 header follows
h[8:10] = (0x7FFE).to_bytes(2,'little')   # SP
h[12] = 0x00        # border 0, no compression
h[27] = 0           # IFF1 off
h[28] = 0           # IFF2 off
h[29] = 1           # IM 1

ext = bytearray(55)                        # additional header length 55 -> hdrlen 87
ext[0:2] = CODE_ORG.to_bytes(2,'little')   # offset 32-33: PC
ext[2]   = 10                              # offset 34: hardware = Scorpion
ext[3]   = 0x00                            # offset 35: #7FFD - bank 0, ROM0, bit5 CLEAR
ext[54]  = 0x00                            # offset 86: #1FFD - no RAM at #0000, no monitor

page = bytes([0xFF, 0xFF, 8]) + bytes(bank5)   # 0xFFFF = uncompressed 16384; page 8 = bank 5

snap = bytes(h) + len(ext).to_bytes(2,'little') + bytes(ext) + page
out = sys.argv[1] if len(sys.argv) > 1 else 'BANKTEST.Z80'
open(out,'wb').write(snap)
print(f"{out}: {len(snap)} bytes, code {len(code)} bytes at #{CODE_ORG:04X}, hdrlen={32+len(ext)}")
