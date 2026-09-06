# Instrumented Fuse: a scriptable reference machine

The Scorpion has no simulator we can boot, and the DE10-Nano tells you only what
the screen shows. This harness turns **Fuse 1.7** — which runs the Scorpion
correctly — into a headless, scriptable reference you can diff the RTL against:
it boots the real ROM set and disk with no X server, drives the boot menu from a
key schedule, dumps screenshots, and logs every paging event with the PC that
caused it.

It is also a **mutation rig**: `ZZ_MUT` switches Fuse's paging rules over to the
(suspected-wrong) rules our RTL implements, so a hypothesis about the core can be
tested against a real machine in seconds instead of a 12-minute Quartus cycle.
That is how the `#8018` Beta-unpage bug was found — see §6 of
`scorpion-zs256-design.md`.

## Build

```bash
curl -sL -o fuse-1.7.0.tar.gz \
  "https://sourceforge.net/projects/fuse-emulator/files/fuse/1.7.0/fuse-1.7.0.tar.gz/download"
tar xzf fuse-1.7.0.tar.gz && cd fuse-1.7.0
patch -p1 < ../tools/fuse-zz-trace.patch
./configure --with-sdl --without-gtk && make -j8
cp /usr/share/fuse/256s-?.rom roms/          # Scorpion ROM set (fuse-emulator-sdl)
```

Arch: `fuse-emulator-sdl` supplies `/usr/share/fuse/256s-0..3.rom`; the build
needs `libspectrum`, `sdl12-compat`, `libpng`.

## Run

No X server needed — SDL's dummy video driver plus Fuse's own `.scr` writer.

```bash
HOME=$PWD/home SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
ZZ_LOG=ev.log ZZ_EXIT=1200 ZZ_SCR=shots/s ZZ_SCR_EVERY=50 \
ZZ_KEYS="650:Enter" ZZ_ARM_FRAME=645 \
./fuse --machine scorpion --no-sound --no-auto-load --speed 100000 real.trd

python3 tools/scr2png.py shots/*.scr        # .scr -> viewable PNG
```

`--no-auto-load` matters: with auto-load on, inserting a `.trd` boots TR-DOS
directly and you never see the Scorpion boot menu.

To run our own ROM set instead of Fuse's bundled `256s-*.rom`, split
`tools/scorp294.rom` into four 16K pages and pass
`--rom-scorpion-N=<file>` — **with the `=`**. The space-separated form is
accepted and silently ignored, which is easy to miss: the machine boots happily
on the bundled ROMs and only the Shadow Monitor's version box (`V2.92` vs
`V2.94`) gives it away.

### Environment

| Variable | Meaning |
|---|---|
| `ZZ_LOG` | trace file; nothing is instrumented unless this is set |
| `ZZ_KEYS` | `frame:key,...` — `Enter`, `Space`, `Caps`, `Symbol`, `0`-`9`, `a`-`z` |
| `ZZ_KEYDUR` | frames a key is held (default 12; the ROM polls at 50 Hz) |
| `ZZ_EXIT` | exit at this frame, after a final `<prefix>final.scr` |
| `ZZ_SCR` / `ZZ_SCR_EVERY` | screenshot prefix / period in frames |
| `ZZ_ARM_FRAME` | suppress the `BETA`/`MAP` firehose until this frame |
| `ZZ_PCMAX` | log this many instructions once armed (`i <pc> <7ffd> <1ffd> <rom> <page> <beta>`) |
| `ZZ_ARM_PC`/`_7FFD`/`_1FFD` | arm the instruction trace on a `beta_page()` matching this state |
| `ZZ_MNI` | pull /NMI and latch `#1FFD[1]` at this frame — the Scorpion's magic button |
| `ZZ_MUT` | bitmask of RTL-divergence mutations, below |

Timings for the Scorpion ROM set: boot menu is up at frame ~600, menu is
navigated with **Caps+6 / Caps+7** (cursor down/up), `Enter` selects. Menu order
is 128 TR-DOS, 128 BASIC, Calculator, 48 BASIC, 48 TR-DOS.

### Log format

```
[ frame/instr] OUT  7ffd,10  PC=e361  pre[7ffd=10 1ffd=12 lock=0 rom=2 page=8 spec=0 beta=0]
[ frame/instr] MAP  rom=1 page=8 spec=0 beta=0 7ffd=10 1ffd=10 lock=0 PC=e367
[ frame/instr] BETA PAGE   PC=3d30 [7ffd=10 1ffd=10 lock=0 rom=1 page=8 spec=0 beta=1]
```

`OUT` is logged for the paging and Beta ports only; `MAP` is every call to
`scorpion_memory_map()`; `BETA` is every `beta_page()`/`beta_unpage()`.

## Mutations

`ZZ_MUT` makes Fuse behave like the RTL where the two are suspected to differ.
A mutation that breaks Fuse identifies a real defect in the core.

| Bit | Fuse rule replaced by the RTL rule | Result |
|---|---|---|
| 1 | Beta unpage on `PC & 0x4000` instead of `PC >= 0x4000` | **breaks** — models the `addr[15:14] & <1 bit>` width bug |
| 2 | `#1FFD[1]` (Shadow Monitor ROM2) outranks the Beta ROMCS at `#0000` | no change |
| 4 | `#1FFD[0]` (RAM at `#0000`) outranks the Beta ROMCS | no change |
| 8 | Beta unpage ignores `current_rom != 0` | no change |
| 16 | `#7FFD` decoded as A15=0 & A1=0, with no A14 term | no change - never exercised |
| 32 | unattached `(port & 0x3f) == 0x1f` reads `#00` while the Beta is paged out | **breaks** — models the ungated Kempston at `addr[5:0] == #1F` |
| 64 | same, but with `#1F`/`#5F` excluded | no change |
| 128 | same, but `#1F`/`#5F` excluded only while `#1FFD[1]` is set | no change — models the shipped fix |

Set `ZZ_ALLOUT=1` to log every `IN`/`OUT` rather than just the paging and Beta
ports; that is how mutations 16 and 32 were found (enumerate the ports the ROM
actually touches, then check each against our decode).

Compare runs by hashing the final screen:

```bash
md5sum shots/sfinal.scr
```

## Adding a mutation

Model the RTL rule as narrowly as possible and gate it on a `zz_mut` bit, so a
single binary can A/B it. They live in `z80/z80_ops.c` (the Beta trap),
`machines/scorpion.c` (the memory map) and `periph.c` (port decode); `zz.h`
exports `zz_mut`.
`z80/coretest.c` links `z80_ops.c` on its own and needs a stub for every new
global.
