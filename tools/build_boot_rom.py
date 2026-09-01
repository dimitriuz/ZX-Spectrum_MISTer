#!/usr/bin/env python3
"""Assemble boot.rom for the ZX Spectrum MiSTer core (Scorpion extension).

Modes:
  --base <existing boot.rom>   append 4 Scorpion pages to a real release ROM
  --synthetic                  192KB of per-chunk patterns + real Scorpion pages
Outputs SHA1 per 16K chunk and full-file SHA256.

--hex <path> additionally writes the output as flat $readmemh hex
(one byte per line, no @offsets) for the sim testbench.
"""
import argparse, hashlib, sys

def sha1(b): return hashlib.sha1(b).hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", help="existing 192KB boot.rom to extend")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--scorp", default="tools/scorp294.rom")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--hex", dest="hexout", help="also write flat $readmemh hex here")
    a = ap.parse_args()

    scorp = open(a.scorp, "rb").read()
    assert len(scorp) == 0x10000

    if a.base:
        base = open(a.base, "rb").read()
        assert len(base) == 0x30000, f"base must be 192KB, got {len(base)}"
    elif a.synthetic:
        base = bytearray()
        for i in range(12):  # 12 x 16K patterned chunks
            base += bytes([(i * 7 + o) & 0xFF for o in range(0x4000)])
        base = bytes(base)
    else:
        sys.exit("need --base or --synthetic")

    out = base + scorp  # Scorpion pages at file offsets 0x30000..0x3FFFF (chunks 12-15)
    open(a.out, "wb").write(out)
    for i in range(len(out) // 0x4000):
        c = out[i*0x4000:(i+1)*0x4000]
        print(f"chunk {i:2d} @0x{i*0x4000:05X}: sha1={sha1(c)}")
    print("full sha256:", hashlib.sha256(out).hexdigest())

    if a.hexout:
        with open(a.hexout, "w") as f:
            for b in out:
                f.write(f"{b:02x}\n")
        print(f"hex written: {a.hexout} ({len(out)} bytes)")

main()
