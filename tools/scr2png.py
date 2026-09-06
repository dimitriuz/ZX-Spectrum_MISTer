#!/usr/bin/env python3
"""Convert a 6912-byte ZX Spectrum .scr to PNG (3x scale)."""
import sys, zlib, struct

PAL = [(0,0,0),(0,0,192),(192,0,0),(192,0,192),(0,192,0),(0,192,192),(192,192,0),(192,192,192),
       (0,0,0),(0,0,255),(255,0,0),(255,0,255),(0,255,0),(0,255,255),(255,255,0),(255,255,255)]

def scr2rgb(d):
    px = [[0]*256 for _ in range(192)]
    for y in range(192):
        third, line, row = y >> 6, (y >> 3) & 7, y & 7
        base = (third << 11) | (row << 8) | (line << 5)
        ay = (y >> 3)
        for cx in range(32):
            b = d[base + cx]
            at = d[6144 + ay*32 + cx]
            ink = (at & 7) | ((at & 0x40) >> 3)
            pap = ((at >> 3) & 7) | ((at & 0x40) >> 3)
            for bit in range(8):
                px[y][cx*8+bit] = ink if (b >> (7-bit)) & 1 else pap
    return px

def png(path, px, scale=2):
    h = len(px)*scale; w = len(px[0])*scale
    raw = bytearray()
    for row in px:
        line = bytearray()
        for c in row:
            r,g,b = PAL[c]
            line += bytes((r,g,b))*scale
        for _ in range(scale):
            raw += b'\x00' + line
    def chunk(t, data):
        c = struct.pack('>I', len(data)) + t + data
        return c + struct.pack('>I', zlib.crc32(t+data) & 0xffffffff)
    out = b'\x89PNG\r\n\x1a\n'
    out += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    out += chunk(b'IDAT', zlib.compress(bytes(raw), 6))
    out += chunk(b'IEND', b'')
    open(path,'wb').write(out)

for f in sys.argv[1:]:
    d = open(f,'rb').read()
    if len(d) < 6912:
        print('short', f); continue
    png(f + '.png', scr2rgb(d))
    print(f + '.png')
