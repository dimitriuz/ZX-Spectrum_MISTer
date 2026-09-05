#!/usr/bin/env python3
"""Build BANKTEST.TAP - a Scorpion ZS-256 RAM paging probe.

Writes a signature into all 16 banks through #C000, then reads them all back.
Run it from 48 BASIC (the paged window at #C000 is unused there, so the test
cannot disturb BASIC itself).

Reading the result:
  0=0,255 .. 15=15,240   paging works, all 16 banks are distinct
  banks 8-15 repeat 0-7  #1FFD bit 4 (the extended page bit) is dead
  all 16 lines identical #7FFD writes are being ignored (bit-5 lockout)
"""
import sys

TOK = {'IF':0xFA,'AND':0xC6,'THEN':0xCB,'FOR':0xEB,'TO':0xCC,'OUT':0xDF,'POKE':0xF4,'NEXT':0xF3,'PRINT':0xF5,
       'PEEK':0xBE,'IN':0xBF,'BORDER':0xE7,'PAPER':0xDA,'INK':0xD9,'CLS':0xFB,
       'LET':0xF1,'REM':0xEA,'STOP':0xE2}

def num(n):
    """ASCII digits followed by the 5-byte inline float BASIC actually evaluates."""
    return list(str(n).encode()) + [0x0E, 0x00, 0x00, n & 0xFF, (n >> 8) & 0xFF, 0x00]

def line(n, *parts):
    body = []
    for p in parts:
        if isinstance(p, int):   body.append(p)          # raw token byte
        elif isinstance(p, str): body += list(p.encode())# literal text
        else:                    body += p               # number sequence
    body.append(0x0D)
    return [n >> 8, n & 0xFF, len(body) & 0xFF, len(body) >> 8] + body

T = TOK
prog = []
# 10-40: write bank number into #C000 of every bank 0-15
prog += line(10, T['FOR'], 'b=', num(0), T['TO'], num(15))
prog += line(20, T['OUT'], num(8189), ',', num(16), '*(b>', num(7), ')', ':',
                 T['OUT'], num(32765), ',', num(16), '+b-', num(8), '*(b>', num(7), ')')
prog += line(30, T['POKE'], num(49152), ',b')
prog += line(40, T['NEXT'], 'b')
# 50: e=mismatches  a=banks 8-15 aliasing 0-7  s=banks reading same as bank 0
prog += line(50, T['LET'], 'e=', num(0), ':', T['LET'], 'a=', num(0), ':', T['LET'], 's=', num(0))
prog += line(60, T['FOR'], 'b=', num(0), T['TO'], num(15))
prog += line(70, T['OUT'], num(8189), ',', num(16), '*(b>', num(7), ')', ':',
                 T['OUT'], num(32765), ',', num(16), '+b-', num(8), '*(b>', num(7), ')')
prog += line(80, T['LET'], 'v=', T['PEEK'], num(49152), ':', T['PRINT'], 'v;" ";')
prog += line(90, T['IF'], 'b=', num(0), T['THEN'], T['LET'], 'f=v')
prog += line(100, T['IF'], 'v<>b', T['THEN'], T['LET'], 'e=e+', num(1))
prog += line(110, T['IF'], 'b>', num(7), T['AND'], 'v=b-', num(8), T['THEN'], T['LET'], 'a=a+', num(1))
prog += line(120, T['IF'], 'v=f', T['THEN'], T['LET'], 's=s+', num(1))
prog += line(130, T['NEXT'], 'b')
# 140-180: verdict - one word plus a border colour
prog += line(140, T['PRINT'], "'", '"1FFD=";', T['IN'], num(8189), "'")
prog += line(150, T['IF'], 'e=', num(0), T['THEN'], T['PRINT'], '"BANKS OK"', ':',
                  T['BORDER'], num(4), ':', T['STOP'])
prog += line(160, T['IF'], 'a=', num(8), T['THEN'], T['PRINT'], '"ALIAS 8-15"', ':',
                  T['BORDER'], num(6), ':', T['STOP'])
prog += line(170, T['IF'], 's=', num(16), T['THEN'], T['PRINT'], '"LOCKED"', ':',
                  T['BORDER'], num(2), ':', T['STOP'])
prog += line(180, T['PRINT'], '"MIXED e=";e;" a=";a;" s=";s', ':', T['BORDER'], num(3))

prog = bytes(prog)

def block(flag, payload):
    body = bytes([flag]) + payload
    chk = 0
    for x in body: chk ^= x
    body += bytes([chk])
    return len(body).to_bytes(2, 'little') + body

name = b'BANKTEST  '[:10]
header = bytes([0]) + name + len(prog).to_bytes(2,'little') \
       + (10).to_bytes(2,'little') + len(prog).to_bytes(2,'little')   # autostart at line 5

tap = block(0x00, header) + block(0xFF, prog)
out = sys.argv[1] if len(sys.argv) > 1 else 'BANKTEST.TAP'
open(out,'wb').write(tap)
print(f"{out}: {len(tap)} bytes  (program {len(prog)} bytes, autostart line 5)")
