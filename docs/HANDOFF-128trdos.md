# Scorpion ZS-256: handoff for the next session

One open bug. Everything else in the machine works and is verified on hardware.
Read "Ruled out" before forming any hypothesis - a lot of plausible ideas are
already dead, with evidence.

## The bug

Selecting **"128 TR-DOS"** from the Scorpion boot menu fails. With ROM v2.94 the
machine resets; with Fuse's v2.92 pages it reaches the TR-DOS `A>` prompt but is
unresponsive. Fuse 1.7 (desktop) and Fuse 1.9 (Android) both run this menu item
correctly with the same ROM and the same disk.

**Workaround that works:** "48 TR-DOS" from the menu, or `RANDOMIZE USR 15616`
from 128 BASIC. Both boot disks and load games, including 256K Scorpion titles.

## What works (do not re-test unless something looks wrong)

Boot, 128/48 BASIC, Calculator; 48 TR-DOS; `USR 15616`; loading games incl. 256K
titles; all 16 RAM banks including extended `#1FFD[4]`; `.z80` snapshots
(hw=10, ARCH_SCORP); Shadow Service Monitor via F11 with all its menus; the
monitor's Disk utility **Test disk** = full surface, 2560 sectors, **0 bad**.

`Monitor > Disk utility > Catalogue` returns `R/W error #9`. **That is not a
bug** - Fuse 1.9 does exactly the same on the same disk, which then loads fine.
Several hours were lost treating it as a symptom.

## The measurement that matters

Entry is provably correct. An in-core capture recorded the first `#3Dxx` M1
fetch at **`#3D30`, `#7FFD=0x10`, `#1FFD=0x10`** - exactly the monitor's RAM
gateway at `#E358` (`#7FFD<-#10 / #1FFD<-#10 / jp #3D30`). The Beta trap arms.

The fault is after that. Two sticky latches, shown on the border, **both fire**
during the attempt:

- `#7FFD` bit 4 is **cleared** while TR-DOS is paged in
- the **`#C000` window is repaged** while TR-DOS is paged in

TR-DOS 5.03 does this itself - its 256K RAM detector writes `#7FFD` from eight
sites in page 3 (`#2B68` = `(#5C01) OR #05`, `#2B7A` = `#00`, `#2C6A` bank scan
0..7, ...); `#7FFD=0x07` was captured on hardware. The monitor keeps everything
it needs to return in that same window (bank 8): `SP = #E2B5`, the `#E34C`
return address, the decrypted gateway blob `#E2DB-#E391`, and the `#DE15/#DE17`
print pointers TR-DOS writes through. Repaging that window destroys the return
path.

This explains the pattern exactly:
- **Test disk works** - drives the WD1793 directly, no TR-DOS call
- **48 TR-DOS / USR 15616 work** - they enter with `#7FFD=#30`; bit 5 sets the
  paging lock, so every TR-DOS `#7FFD` write is a silent no-op
- **128 TR-DOS fails** - enters with `#7FFD=#10`, unlocked, so they all land

## The open question

Fuse survives the same writes with the same page arithmetic
(`page = {1FFD[4], 7FFD[2:0]}`, identical to ours). **Why does the repaged
`#C000` window break the return path here and not in Fuse?**

Next step is a Fuse trace of the bank across that call (breakpoint at `#E358`,
step through `jp #3D30` and the TR-DOS routine, watch `#7FFD` and the mapped
page), compared against the in-core capture. Not another RTL guess.

## Ruled out, with evidence

| Hypothesis | Killed by |
|---|---|
| The ROM build (v2.94 vs Fuse's v2.92) | fails identically with Fuse's own `256s-0..3.rom`, which differ in pages 2 and 3 |
| The disk image | same image boots in Fuse and via 48 TR-DOS here |
| FDC / `wd1793` disk timing | monitor's Test disk: 2560 sectors, 0 bad |
| Memory contention | Pentagon timing changes nothing (Fuse and MAME both say the Scorpion has none - still worth fixing separately) |
| Beta trap arming condition | aligned to Fuse (`current_rom != 0` = ROM1 or ROM2, never ROM0); no change |
| ROM page priority / TR-DOS ROMCS | both fixed against MAME; no change |
| Unattached ports reading floating bus | now `0xFF` per Fuse; no change |
| Beta port decode missing bit 0 | real bug, fixed (`#FE` was aliasing onto `#FF`); no change to this failure |
| Enabling Beta ports when ROM2 is paged | tried, reverted - neither Fuse nor MAME does it |

## Branches

- `scorpion-zs256` - working branch: feature + all fixes + debug facilities +
  test tooling + retired `sim/`.
- `scorpion-zs256-pr` - upstream PR branch: 7 files, debug scaffolding stripped,
  `sys/` untouched, `rtl/` untouched except `snap_loader.sv`.

## Remote control of the MiSTer (this all works, reuse it)

MiSTer at `192.168.1.29`, root/1. Helpers in the session scratchpad:

- `sshrun.py` - ssh/scp over a pty (no `sshpass` on this box)
- `mkeys.py` - virtual keyboard via `/dev/uinput`; **keep it at
  `/media/fat/mkeys.py`**, `/tmp` is wiped on the MiSTer
- `shot.sh` - inject keys, screenshot, pull the PNG back
- `echo load_core <path> > /dev/MiSTer_cmd` loads a core;
  `echo screenshot > /dev/MiSTer_cmd` writes to
  `/media/fat/screenshots/Spectrum/`

Gotchas learned the hard way:

- **F12 does not open the OSD** from the virtual keyboard (MiSTer only accepts
  the menu key from an assigned device). Build test cores with `scorp <= 1'b1`
  and `dbg_sel` ungated so no OSD is needed.
- **Keys need a ~0.2 s hold** - the Spectrum ROM polls at 50 Hz and a 12 ms tap
  is missed.
- **`load_core` loses the disk mount and resets OSD settings.** There is no
  mount command; the user has to re-mount.
- **`boot.rom` only refreshes on a full MiSTer reboot**, not on `load_core`. Two
  ROM comparisons were invalidated by this.
- Quartus rewrites `LAST_QUARTUS_VERSION` in the `.qsf` every build - always
  `git checkout -- ZX-Spectrum.qsf` afterwards.
- Build with `setsid nohup docker run --rm --name <n> ...`; the harness's memory
  watchdog kills managed background tasks mid-compile.

## Debug facilities on `scorpion-zs256` (off by default)

- **Debug Border** `status[43:42]`: 1 = `{trdos_en, #1FFD[1], #7FFD[4]}`,
  2 = `{trdos_en, bit4-cleared-while-TRDOS, bank-moved-while-TRDOS}`
- **Debug Port** `status[44]`: 16 read-only registers at `#7AF0-#7AFF` - state
  captured at the first `#3Dxx` fetch, `#3Dxx`/`trdos_en` counts, FDC activity,
  and an **`0xA5` sentinel at `#7AFF`**. *Always check the sentinel first* - a
  16-register reader was once run against an 8-register core and the floating
  bus read as plausible data.
- `tools/make_dbgread_z80.py`, `tools/make_dbgfdc_z80.py`,
  `tools/make_bank_test_z80.py` build `.z80` snapshots that read these back and
  paint them as bit grids. Snapshots are far more reliable than tape here.
- The capture survives a **soft** reset (only an `OUT` to the debug port clears
  it), so you can trigger a failure and then read it back. It does **not**
  survive `load_core`, which reconfigures the FPGA.

## References

- Fuse source: `machines/scorpion.c`, `peripherals/disk/beta.c`,
  `z80/z80_ops.c` (the ROMCS trap is at ~line 176). Fuse is a cleaner reference
  than MAME - MAME's `((nmi_pending || dos()) << 1) | rom1()` conflates the
  magic-button NMI with the Beta trap and misled several attempts.
- MAME: `src/mame/sinclair/scorpion.cpp`.
- The Scorpion ROM disassembly findings (gateway at `#E358`, menu table at
  `#2744`, page 0/2 `OUT` trampolines at `#0004/#001C/#0024`) are summarised in
  `docs/scorpion-zs256-design.md` section 6.

## A process note

Roughly ten fixes were proposed for this bug from reading emulator source; about
two were right and three caused regressions that had to be backed out. Every
real advance came from a measurement: the sticky border trace, the ROM
disassembly, the bank test, and the user's own A/B observations. **Measure
first.** And validate the test fixture before trusting a result - a blank TRD
with no boot file, and a `boot.rom` that had not actually been reloaded, each
produced a confident but wrong conclusion.
