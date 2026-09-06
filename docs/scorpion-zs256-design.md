# Scorpion ZS-256 Support — Design

New machine mode for the ZX Spectrum MiSTer core: **Scorpion ZS-256** (St. Petersburg, S. Zonov, 1993–1998), base model (no GMX/Turbo+ extensions).

## 1. Verified hardware reference

Sources: Fuse `machines/scorpion.c` (reference implementation), speccy-bootcamp `02_hardware/clones/scorpion.md`, romychs/Scorpion256TPlus repo, Wikipedia.

| Item | Value |
|---|---|
| CPU | Z80 @ 3.5 MHz ("turbo" 7 MHz = existing core turbo feature) |
| RAM | 256 KB = 16 × 16 KB banks (expandable to 1 MB on real HW; we do 16 banks) |
| Paging | `#7FFD` bits 2:0 + `#1FFD` bit 4 → bank 0–15 at #C000–#FFFF; #4000–#7FFF fixed to bank 5 (screen), #8000–#BFFF fixed to bank 2 |
| Screen bank | `#7FFD` bit 3: 0 → bank 5, 1 → bank 7 (display file always in one of these two) |
| ROM select at #0000 | `#1FFD` bit 0 → RAM bank 0; else `#1FFD` bit 1 → ROM2 (Shadow Service Monitor); else `#7FFD` bit 4: 0 → ROM0 (BASIC 128), 1 → ROM1 (48K BASIC) |
| ROM | 64 KB = 4 × 16 KB pages: ROM0 "Scorpion BASIC 128" ("1992-94 Scorpion ZS 256"), ROM1 48K BASIC, ROM2 Shadow Service Monitor (pure code, RU UI), ROM3 TR-DOS 5.03 |
| Video | Standard ULA-48 timings: 312 lines, 69,888 T-states, INT at T=0, #FF = attribute byte |
| Disk | Beta 128 (TR-DOS) **built-in**, always active; ROM3 is the TR-DOS entry ROM |
| Sound | AY-3-8910/12 at #FFFD/#FFFE (existing path) |
| Ports | Kempston joystick (#FFFD), standard ULA ports; #FE uses selective decode (A4,A3,A1,A0) — see limitations |
| MNI button | Physical "Magic" button on case: triggers NMI into Shadow Service Monitor |
| Keyboard | 58-key full-size layout (different matrix from membrane) — see limitations |

ROM source: `scorp294-99f57ce1-recomended.rom` from romychs/Scorpion256TPlus (SHA256 `f10e9daa1ff302247322b01c1ec63547e18d56a2ab3c62579f2b5c7fafd0ddeb`, 64 KB). Per-page SHA1:

| Page | Content | SHA1 (16 KB) |
|---|---|---|
| 0 | Scorpion BASIC 128 | `477114ff0fe1388e0979df1423602b21248164e5` |
| 1 | 48K BASIC (Scorpion build) | `367b5a102fb663beee8e7930b8c4acc219c1f7b3` |
| 2 | Shadow Service Monitor | `5ecf853611870802b07527cdb78cae553adc761d` |
| 3 | TR-DOS 5.03 | `a95e48399622e5b7cfda6aa724c5b1c62d892c97` |

Note: page 1 is **not** byte-identical to either existing 48K BASIC chunk in boot.rom (verified by hash) — it gets its own ROM slot.

## 2. Key decisions (agreed)

- **MNI = F11.** The core's bare-F11 NMI key is reused: in Scorpion mode, pressing F11 writes `#1FFD ← 0x02` (Shadow Monitor select) and pulses NMI — CPU jumps to #0066 which is now Shadow Monitor code. No new key; consistent with existing NMI usage (F11 = NMI for MF/+3 today).
- **ROM v2.94** ("recomended" in the source repo).
- Base ZS-256 only (no GMX graphics expander, no Turbo+ ISA/IDE).
- **Border power-on value.** `border_color` is explicitly initialized to 0, matching the FPGA flip-flop power-up state. v2.94 never writes port #FF during boot (ROM scan: no `OUT (#FF),A` in pages 0-2), so the border latch is never written before the user reaches TR-DOS - the initializer makes that starting value explicit rather than implicit.

## 3. SDRAM address map

The SDRAM controller (`rtl/sdram.sv`, MT48LC16M16A2) decodes the full 25-bit logical
address — there is no aliasing:

`bank = addr[24:23]` (line 173), `row = addr[13:1]` (line 172), `column = addr[22:14]`
(line 181), `byte select = addr[0]`.

So a logical address is simply a linear byte address into the 32 MB part, and the ROM
window prefix has to be chosen to land exactly on where the host put the data:

- boot.rom (host download, ioctl index 0) is written at base `0x150000`
  (`load_addr`, `ZX-Spectrum.sv:415`), so file offset *o* lives at `0x150000 + o`.
- The existing ROM window `{3'b101, page_rom, addr[13:0]}` = `0x140000 + p*0x4000`
  therefore reaches file offset `(p-4)*0x4000`. Cross-checked against the README chunk
  table: p=4 (shadow_rom) → glukpen @ 0x00000 ✓, p=5 (trdos_en) → TR-DOS @ 0x04000 ✓,
  p=12 (plusd_mem) → +D ROM @ 0x20000 ✓, p=13 → MF128+Genie @ 0x24000 ✓,
  p=14 (MF3/+3) → mf3 @ 0x28000 ✓, p=15 (zx48) → 48.rom @ 0x2C000 ✓.
  With only 4 bits of `page_rom`, that window tops out at file offset 0x2FFFF — exactly
  the end of the old 192 KB boot.rom.

The four Scorpion pages are appended at file offsets `0x30000…0x3FFFF`, i.e. logical
`0x180000…0x18FFFF`, which the existing prefix cannot express. Solution: a **mode-gated
ROM window prefix** — in Scorpion mode the #0000–#3FFF decode uses
`{3'b110, page_rom, addr[13:0]}` (`0x180000 + p*0x4000`). Existing machines keep the old
prefix, so their mapping is bit-for-bit unchanged.

| Scorpion page_rom | Logical address | boot.rom offset | Content |
|---|---|---|---|
| 0 | 0x180000 | 0x30000 | ROM0 Scorpion BASIC 128 |
| 1 | 0x184000 | 0x34000 | ROM1 48K BASIC |
| 2 | 0x188000 | 0x38000 | ROM2 Shadow Service Monitor |
| 3 | 0x18C000 | 0x3C000 | ROM3 TR-DOS 5.03 |
> Note: speccy-bootcamp's "ROM Page Contents" table lists ROM2 = TR-DOS and ROM3 = Shadow Monitor, but that contradicts both Fuse (`scorpion.c`: `#1FFD` bit 1 → rom 2) and the worldofspectrum Scorpion FAQ ("port 1ffd D1 — selects ROM expansion. this rom contains main part of service monitor"). This implementation follows Fuse/worldofspectrum: Shadow Monitor is the `#1FFD`-bit-1 ROM; TR-DOS enters via the Beta FDC ROMCS path (emulated by `trdos_en`).

## 4. Per-file changes

### ZX-Spectrum.sv (top level)

1. **Machine flag**: `wire scorp = (status[12:10] == 5);` set on reset alongside p1024/pf1024/zx48/plus3 (line ~534). Value 5 is free (OSD Memory option currently uses 0–4).
2. **OSD menu** (line 95): append `,Scorpion ZS-256` to the `P2O[12:10],Memory,…` string.
3. **ROM decode** (line 419): `ram_addr = scorp ? {3'b110, page_rom, addr[13:0]} : {3'b101, page_rom, addr[13:0]};`
4. **Scorpion ROM selection**: in Scorpion mode the existing esxdos/shadow/trdos/plusd/mf128 casex arms (lines 499–507) are bypassed; instead (`page_rom` values 0–3 → columns 32–35):
   - `#1FFD` bit 0 set → page_rom = 0, with a decode override putting RAM bank 0 at #0000 (see 5);
   - `#1FFD` bit 1 set → page_rom = 2 (Shadow Monitor);
   - else `#7FFD` bit 4: 1 → page_rom = 1 (48K BASIC), 0 → page_rom = 0 (BASIC 128).
   - TR-DOS entry (ROM3) is reached by the built-in Beta 128 FDC path, not via #0000 ROM select — in Scorpion mode `trdos_en` forces page_rom = 3 while a disk is active. The #3Dxx M1 trap is gated on `scorp_rom1 = ~#1FFD[0] & (#1FFD[1] | #7FFD[4])`, matching Fuse's `ram.current_rom != 0`: it arms from ROM1 (48 BASIC) or ROM2 (the Shadow Monitor, which is how the 128 menu's TR-DOS entry gets there), never from ROM0 - BASIC 128 has genuine subroutines of its own at #3D9D-#3DE9 - and never with RAM bank 0 mapped at #0000. The matching page-out is `(|addr[15:14]) & (~scorp | scorp_cur_rom)`; see section 6 for why the reduction OR is load-bearing.
5. **#1FFD register**: new `reg [7:0] scorp_1ffd`. Write decode: `scorp_1ffd_wr = scorp & ~addr[15] & ~addr[1] & addr[12] & ~addr[13] & ~addr[14]` (#1FFD), latching `cpu_dout` on the io_wr edge. Cleared to 0 on reset. Port read conformance (speccy-bootcamp): #7FFD is **write-only** (no mux arm — reads fall through to the ULA port like other unattached ports); #1FFD reads return **#FF** on non-Turbo boards (this core models the base ZS-256, no Turbo), so `cpu_din` has one Scorpion arm: `(scorp & addr[14:0]==15'h1FFD) ? 8'hFF`. Shadow Monitor exit is a #1FFD *write* (=0), not a read.
6. **Paging** (lines 420–422): in Scorpion mode the map matches real hardware (Fuse `scorpion_memory_map` + speccy-bootcamp): #4000–#7FFF stays fixed to bank 5, #8000–#BFFF fixed to bank 2, and only #C000–#FFFF is paged: `ram_addr = {1'b0, scorp_page[3:0], addr[13:0]}` where `scorp_page = {scorp_1ffd[4], page_reg[2:0]}`. Bank *b* therefore occupies SDRAM column *b* (offsets 0–0x3FFF within the bank). **Bit-5 lockout** (worldofspectrum FAQ: "D5 — 1 in this bit will block further output in port 7FFD, until reset"; Fuse `spec128_memoryport_write`: `if(locked) return; … locked = b & 0x20`): `scorp_lock = scorp & page_reg[5]` gates the **#7FFD** write latch only — the locking write itself applies, all later #7FFD writes are ignored until machine reset. #1FFD is deliberately *not* locked: both the FAQ text and Fuse scope the lock to #7FFD, and locking #1FFD would trap the machine in the Shadow Monitor, whose exit path is a #1FFD write (48 BASIC sets bit 5 on entry, so this is the common case, not a corner case). Implemented as a separate wire (not via `page_disable`) so the tape player's `.mode48k(page_disable)` input is unaffected in Scorpion mode.
7. **vram mirror** (line ~485): no new logic needed — the existing `vram_we` first term `((ram_addr[24:16]==1) & ram_addr[14])` already mirrors every legitimate Scorpion screen-bank write into the ULA dpram at `{bank-half, addr[13:0]}` (column 5 via #4000 → half 0; columns 5/7 via paged #C000 → half = column[1]). An earlier draft added a `scorp_vram` term, but it mirrored non-screen writes through #C000/#8000 and was removed; Scorpion keeps the identical mirror semantics as all other machines. Verified by `test_paging` dpram checks (mirror on page 5/7 and #4000, no mirror on data banks).
8. **MNI (F11)**: on a bare-F11 rising edge (mod==0) in Scorpion mode, `mni_pulse` sets `mni_pending`, and the paging block applies `scorp_1ffd <= {scorp_1ffd[7:2], 1'b1, scorp_1ffd[0]}` — a hardware set of **bit 1 only**, so the CPU's #0066 fetch lands in the Shadow Monitor while the extended page bit (bit 4 = `scorp_page[3]`) and every other bit survive. Clobbering bit 4 here would silently repage #C000 under the interrupted program, and since #1FFD is write-only nothing could restore it. The latch is hardware, not a port write, so it is not gated by the bit-5 lockout. Clearing happens by software writing #1FFD (monitor exit). Routing the set through `mni_pending` keeps `scorp_1ffd` single-driver (Quartus Error 10028).
9. **snap_loader** (line ~283): add `ARCH_SCORP` parameter, pass to instance; on Scorpion snapshot load restore `page_reg` and `scorp_1ffd`.
10. **DivMMC disabled** (line ~977): `mmc_mode` is forced to `2'b00` in Scorpion mode. A real Scorpion has no DivMMC, and leaving it enabled is actively broken here — `mmc_ram_en` outranks the ROM decode in the `ram_addr` casex, so DivMMC RAM would page in at #2000–#3FFF, while `mmc_rom_en` can never select the esxdos ROM because the Scorpion branch bypasses the `page_rom` casex. Forcing the mode off (rather than gating the consumers) also keeps `~&mmc_mode` true, so the TR-DOS #3Dxx trap still works with a VHD mounted.

### rtl/snap_loader.sv

- New parameter `ARCH_SCORP`.
- z80 hardware ID: `10: snap_hw <= ARCH_SCORP;` (LIBSPECTRUM_MACHINE_SCORP = 10, verified against libspectrum.h enum).
- Scorpion snapshot load: restore #7FFD/#1FFD registers from the snapshot's machine state (same pattern as existing `page_reg <= snap_7ffd`).

### rtl/ula.sv

- **No changes.** Video uses ULA-48 timings (mZX=1, m128=0 — select "Video Timings → ULA-48" or leave default for this machine; Scorpion video is stock 48K). Contention (`contendAddr`, line 258) keeps the standard #4000–#7FFF window: in Scorpion mode this matches real behavior when the screen bank (5/7) is paged into that window, and adds a conservative spurious wait otherwise — acceptable for v1.

### boot.rom

Append 4 × 16 KB chunks (file grows 0x30000 → 0x40000):

| N | Base Offset | Size | SHA1 | Description |
|---:|---:|---:|:---:|:---|
| 16 | 30000 | 4000 | `477114ff…` | Scorpion ROM0 — BASIC 128 (1992-94) |
| 17 | 34000 | 4000 | `367b5a10…` | Scorpion ROM1 — 48K BASIC |
| 18 | 38000 | 4000 | `5ecf8536…` | Scorpion ROM2 — Shadow Service Monitor |
| 19 | 3C000 | 4000 | `a95e4839…` | Scorpion ROM3 — TR-DOS 5.03 |

Host streams the whole file with index 0 — no host-side changes.

### README.md

- Feature list: add "Scorpion ZS-256".
- boot.rom table: rows 16–19 above + full-file SHA256 of the new 256 KB image.
- OSD docs: Memory option value, F11 = MNI/Shadow Monitor entry in Scorpion mode.

## 5. Verification plan (hardware)

Build with Quartus 17.0.2 (Cyclone V, 5CSEBA6U23I7), copy `output_files/ZX-Spectrum.rbf`
to the DE10-Nano, and run through:

1. **Boot**: Memory = Scorpion ZS-256, reset → ROM0 "Scorpion BASIC 128" banner.
2. **ROM select**: enter 48 BASIC (`#7FFD` bit 4) → ROM1 banner; confirm the 48K lock
   (`#7FFD` bit 5) blocks further #7FFD writes but still allows #1FFD.
3. **Paging**: from BASIC, `OUT` sequences over `#7FFD` bits 2:0 and `#1FFD` bit 4 —
   all 16 banks addressable at #C000, #4000 pinned to bank 5, #8000 pinned to bank 2.
4. **Screen bank**: `#7FFD` bit 3 → display switches between bank 5 and bank 7.
5. **MNI**: F11 → Shadow Service Monitor at #0066. Page a high bank (8–15) at #C000
   first and confirm it is *still* there inside the monitor (bit-4 preservation), then
   exit via the monitor's own exit and confirm ROM0/ROM1 and the bank both come back.
6. **TR-DOS**: mount a TRD/SCL, enter TR-DOS from the ROM0 menu and from 48 BASIC
   (`RANDOMIZE USR 15616`); read and write a file. Confirm the trap does *not* fire
   while the Shadow Monitor is paged in.
7. **Snapshot**: load a Scorpion .z80 (hw=10) — registers, both paging ports and all
   16 banks restored.
8. **No regression on machines 0–4**: boot 48K, 128K, +2A/+3, Pentagon 128 and
   Pentagon 1024; on the +3 specifically, mount a .dsk, **reset, and confirm the drive
   is still ready** (this is the path the reverted `u765.sv` change broke).

## 6. Solved: the "128 TR-DOS" menu item

Selecting **"128 TR-DOS"** from the Scorpion boot menu used to stop dead on the
"128 TR-DOS" banner (ROM 2.94) while 48 TR-DOS, `RANDOMIZE USR 15616` and the
Shadow Monitor all worked. Two independent RTL bugs were behind it; both are
fixed, and both were first reproduced in an instrumented Fuse 1.7 before the RTL
was touched (see `fuse-harness.md`).

### Bug 1 - the Beta ROM was never paged out in `#8000-#BFFF`

```systemverilog
if(addr[15:14] & (~scorp | scorp_cur_rom)) trdos_en <= 0;   // wrong
if((|addr[15:14]) & (~scorp | scorp_cur_rom)) trdos_en <= 0; // fixed
```

A bitwise `&` extends its operands to the wider one and zero-extends the
1-bit side, so `addr[15:14] & <1 bit>` is `{1'b0, addr[14] & cond}` - the
`addr[15]` term is silently dropped and TR-DOS is never paged out anywhere in
`#8000-#BFFF`. Measured with iverilog rather than assumed:

```
  PC     as-written  reduction-OR   plain
  8018      0            1           1
```

That matters because the TR-DOS boot loader ends by jumping to `#8018`, where
the reference pages the Beta ROM out (`BETA UNPAGE PC=8018`, the last beta event
of the run) - so the file browser ran with the TR-DOS ROM still over
`#0000-#3FFF`. The same expression governs every machine, so this had also
regressed 48 TR-DOS and the Pentagon.

### Bug 2 - the Kempston answered the Beta status port

```systemverilog
wire kemp_sel = addr[5:0] == 6'h1F;                                   // wrong
wire kemp_sel = (addr[5:0] == 6'h1F) & ~(scorp & beta_port & scorp_1ffd[1]); // fixed
```

The Kempston decode is six bits wide - it answers `#1F`, `#5F`, `#9F` and `#DF` -
and it is unconditional, sitting *below* `fdc_sel` in the `cpu_din` mux. So with
TR-DOS paged out it also answered `#1F` and `#5F` with the empty joystick `#00`
rather than the `#FF` an unattached port reads.

The Shadow Monitor polls the WD1793 status through `#xx1F` **after** paging
TR-DOS out, and spins until the value is non-zero:

```
0234: 21 05 E0   ld hl,#E005
0237: DB 1F      in a,(#1F)
0239: A4         and h        ; mask #E0
023A: 28 FB      jr z,#0237   ; loop while zero
```

`#FF & #E0` exits; `#00 & #E0` loops forever. That is the banner hang, and the
machine's own Shadow Monitor confirmed it on hardware: `A = #00`, `HL = #E005`
(the mask this code loads), `SP = #E2B1`, `IX/IY` the monitor's own constants.

Handing the whole Beta range back unconditionally is wrong the other way -
Kempston is active high, so `#FF` reads as every direction plus fire held down,
and a Fuse trace shows the TR-DOS file browser polling `#0C1F` (`PC=#84EF`)
about 97,000 times. The two callers are separated by `#1FFD[1]`: only the Shadow Monitor runs
with its own ROM2 paged in, so that is the one case where the Beta ports win and
everything else keeps the joystick.

### Why the other routes always worked

**48 TR-DOS** and **`USR 15616`** enter TR-DOS directly and never execute the
monitor's return stub, so they never reach the `#0237` poll. 48 TR-DOS also
enters with `#7FFD=#30`, where bit 5 locks paging.

### What is still loose (latent, not exercised)

- `fdd_sel` decodes only `addr[2:0]` plus `addr[7]`, so it claims far more than
  Fuse's `#1F/#3F/#5F/#7F/#FF`. The reference writes `#00F7` once (`PC=#5C95`)
  and reads `#00F7` once - both with the interface paged out, so neither bites
  today, but `OUT (#F7),#00` would assert `fdd_reset` if it ever happened while
  TR-DOS was paged in.
- `page_write` for the Scorpion is `~A15 & ~A1` with no A14 term, so it is wider
  than Fuse's `0xc002/0x4000`. No port in the reference trace exercises the
  difference (verified with `ZZ_MUT=16`, zero hits).

## 7. Debug facilities

Two OSD-gated aids, both off by default and inert unless selected:

- **Debug Border** (`status[43:42]`): 1 = ROM page
  `{trdos_en, #1FFD[1], #7FFD[4]}`, 2 = repaging trace
  `{trdos_en, #7FFD bit4 cleared while TR-DOS, #C000 bank moved while TR-DOS}`.
- **Debug Port** (`status[44]`): 16 read-only registers at `#7AF0-#7AFF` - the
  machine state captured at the first `#3Dxx` fetch, `#3Dxx`/`trdos_en` counts,
  FDC activity, and an `0xA5` sentinel at `#7AFF` so a dead port cannot be
  mistaken for data. `#7AFx` is Turbo+/GMX territory the base ZS-256 ROM never
  touches (confirmed by disassembling pages 0 and 2).

`tools/make_dbgread_z80.py` and `tools/make_bank_test_z80.py` build `.z80`
snapshots that read these back and display them as bit grids. From the boot
menu's 128 BASIC, `print in 31472` … `print in 31487` reads them directly, which
needs no snapshot loading and so can be driven entirely over ssh - see
`hardware-testing.md`.

**Read the port, never write it.** `#7AF0` has A15=0, A14=1, A1=0, so a write
lands on `#7FFD` (in Fuse too - its mask is `0xc002`/`0x4000`) and takes the
machine down with it. `OUT 31472,0` does clear the capture, but only as it
crashes BASIC; reset afterwards. The capture survives a reset - only that OUT
clears it - so it is cumulative across runs, and a count or "last value"
register read after a second boot includes that boot's activity.

## 8. Other known limitations / stretch goals

- **#FE selective decode** (A4,A3,A1,A0 per bootcamp notes) not modeled — standard ULA-48 #FE used. Needs Turbo+ schematics/GAL netlist for exactness.
- **Keyboard matrix**: PS2 keys map via the existing membrane scan-code table; the Scorpion's 58-key full-size matrix is not emulated (no functional loss for most software; key *positions* differ from a real Scorpion keyboard).
- **MNI flag port**: real HW likely exposes an MNI-pressed flag at some port that ROM0's NMI handler reads; we bypass that by latching the shadow page directly on F11. If ROM0's handler misbehaves without the flag, revisit (may need a fake flag byte at a TBD address).
- **DivMMC / esxdos** is disabled in Scorpion mode (no such hardware on a real Scorpion; the built-in Beta 128 covers disk access).
- **Turbo+ / GMX** variants: out of scope.
- **Contention approximation**: see §4 ula.sv note.
- **Untested on hardware at time of writing** — §5 has not been executed yet.
