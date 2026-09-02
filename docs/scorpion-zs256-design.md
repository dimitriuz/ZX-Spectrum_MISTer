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
- **Sim-first verification.** No MiSTer hardware available yet: build an iverilog testbench harness first, flash-test on real hardware later.
- **ROM v2.94** ("recomended" in the source repo).
- Base ZS-256 only (no GMX graphics expander, no Turbo+ ISA/IDE).
- **Border power-on value.** `border_color` is initialized to 0 (FPGA flip-flops power up at 0). v2.94 never writes port #FF during boot (ROM scan: no `OUT (#FF),A` in pages 0-2), so without the init the Scorpion border would be X in sim, unlike real hardware where the ULA latch powers up defined.

## 3. SDRAM aliasing (derived, to be confirmed by sim)

The SDRAM controller (`rtl/sdram.sv`, MT48LC16M16A2) decodes a 25-bit logical address as:
`bank = addr[23]`, `row = addr[13:1]`, `column = addr[19:14]`, `byte = addr[0]`; bits [24, 22:20] are ignored.

Consequences (verified against known-good mappings):
- boot.rom chunks (host download, ioctl index 0, base `0x150000`): chunk *i* → column `20+i`.
- Existing ROM window (`{3'b101, page_rom, r}` = `0x140000 + p*0x4000`): page_rom *p* → column `16+p`, i.e. file offset `(p−4)*0x4000`. Cross-checked against the README chunk table: p=5 (trdos_en) → TR-DOS @ 0x4000 ✓, p=4 (shadow_rom) → glukpen @ 0x00000 ✓, p=12 (plusd_mem) → +D ROM @ 0x20000 ✓, p=13 → MF128+Genie slot @ 0x24000 ✓, p=14 (MF3/+3) → mf3 @ 0x28000 ✓, p=15 (zx48) → 48.rom @ 0x2C000 ✓.

New Scorpion chunks appended to boot.rom at file offsets `0x30000…0x3FFFF` land in **columns 32–35** (base `0x150000`: column = 20 + offset/0x4000), which no existing ROM-window value reaches (existing prefix `{3'b101,…}` → columns 16–31). Solution: a **mode-gated ROM window prefix** — in Scorpion mode the #0000–#3FFF decode uses `{3'b110, page_rom, r}` (`0x180000 + p*0x4000` → column `32+p`). Existing machines keep the old prefix — zero behavior change for them.

| Scorpion page_rom | Column | boot.rom offset | Content |
|---|---|---|---|
| 0 | 32 | 0x30000 | ROM0 Scorpion BASIC 128 |
| 1 | 33 | 0x34000 | ROM1 48K BASIC |
| 2 | 34 | 0x38000 | ROM2 Shadow Service Monitor |
| 3 | 35 | 0x3C000 | ROM3 TR-DOS 5.03 |
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
   - TR-DOS entry (ROM3) is reached by the built-in Beta 128 FDC path, not via #0000 ROM select — in Scorpion mode `trdos_en` forces page_rom = 3 while a disk is active.
5. **#1FFD register**: new `reg [7:0] scorp_1ffd`. Write decode: `scorp_1ffd_wr = scorp & ~addr[15] & ~addr[1] & addr[12] & ~addr[13] & ~addr[14]` (#1FFD), latching `cpu_dout` on the io_wr edge. Cleared to 0 on reset. Port read conformance (speccy-bootcamp): #7FFD is **write-only** (no mux arm — reads fall through to the ULA port like other unattached ports); #1FFD reads return **#FF** on non-Turbo boards (this core models the base ZS-256, no Turbo), so `cpu_din` has one Scorpion arm: `(scorp & addr[14:0]==15'h1FFD) ? 8'hFF`. Shadow Monitor exit is a #1FFD *write* (=0), not a read.
6. **Paging** (lines 420–422): in Scorpion mode the map matches real hardware (Fuse `scorpion_memory_map` + speccy-bootcamp): #4000–#7FFF stays fixed to bank 5, #8000–#BFFF fixed to bank 2, and only #C000–#FFFF is paged: `ram_addr = {1'b0, scorp_page[3:0], addr[13:0]}` where `scorp_page = {scorp_1ffd[4], page_reg[2:0]}`. Bank *b* therefore occupies SDRAM column *b* (offsets 0–0x3FFF within the bank). **Bit-5 lockout** (worldofspectrum FAQ: "D5 — 1 in this bit will block further output in port 7FFD, until reset"; Fuse `spec128_memoryport_write`: `if(locked) return; … locked = b & 0x20`): `scorp_lock = scorp & page_reg[5]` gates both the #7FFD and #1FFD write latches — the locking write itself applies, all later paging writes are ignored until machine reset. Implemented as a separate wire (not via `page_disable`) so the tape player's `.mode48k(page_disable)` input is unaffected in Scorpion mode.
7. **vram mirror** (line ~485): no new logic needed — the existing `vram_we` first term `((ram_addr[24:16]==1) & ram_addr[14])` already mirrors every legitimate Scorpion screen-bank write into the ULA dpram at `{bank-half, addr[13:0]}` (column 5 via #4000 → half 0; columns 5/7 via paged #C000 → half = column[1]). An earlier draft added a `scorp_vram` term, but it mirrored non-screen writes through #C000/#8000 and was removed; Scorpion keeps the identical mirror semantics as all other machines. Verified by `test_paging` dpram checks (mirror on page 5/7 and #4000, no mirror on data banks).
8. **MNI (F11)** — *planned, Task 4 (not yet in RTL)*: in the F11 NMI block (lines 392–396), when `scorp` and bare F11 (mod==0) rising edge: also set `scorp_1ffd <= {6'b0, 1'b1, scorp_1ffd[0]}` before/at the NMI pulse so the CPU's #0066 fetch lands in Shadow Monitor (bit 1 = ROM2; bit 0 kept). The MNI latch is hardware (not a port write) so it will NOT be gated by the bit-5 lockout. Clearing happens by software writing #1FFD (monitor exit) — no extra hardware latch needed.
9. **snap_loader** (line ~283): add `ARCH_SCORP` parameter, pass to instance; on Scorpion snapshot load restore `page_reg` and `scorp_1ffd`.

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

## 5. Verification plan (sim first)

1. **Testbench** (iverilog): instantiate `emu` with stubbed sys ports; feed clk_sys; simulate the MiSTer host's boot.rom download (index 0, 16 KB blocks).
2. **Alias check**: read back every new chunk through its Scorpion ROM window (page_rom 4–7) and byte-compare against the source file — confirms §3 on real controller logic before any hardware exists.
3. **Boot test**: machine=Scorpion, reset → CPU must execute ROM0; verify BASIC banner bytes at #5000+ after boot sequence, screen RAM (bank 5) updated, border color set.
4. **Paging test**: OUT (#7FFD)/OUT (#1FFD) sequences per §1 table — verify bank contents appear at the right windows, ROM select chain (incl. Shadow Monitor via #1FFD bit 1), screen-bank switch (bit 3) reflected in vram/video address.
5. **MNI test**: F11 pulse → NMI + #1FFD=0x02 → CPU at #0066 in ROM2; then write #1FFD=0 → ROM0 restored.
6. **Snapshot test**: load a Scorpion .z80 (hw=10) — registers restored, machine runs.
7. **Regression**: existing machines (ZX48/ZX128/+3/P1024) decode unchanged — diff ram_addr for identical stimulus pre/post change in sim.
8. **Hardware flash-test** (later): build .rbf, flash, boot Scorpion BASIC, run a TR-DOS disk image, enter Shadow Monitor via F11.

## 6. Known limitations / stretch goals

- **#FE selective decode** (A4,A3,A1,A0 per bootcamp notes) not modeled — standard ULA-48 #FE used. Needs Turbo+ schematics/GAL netlist for exactness.
- **Keyboard matrix**: PS2 keys map via the existing membrane scan-code table; the Scorpion's 58-key full-size matrix is not emulated (no functional loss for most software; key *positions* differ from a real Scorpion keyboard).
- **MNI flag port**: real HW likely exposes an MNI-pressed flag at some port that ROM0's NMI handler reads; we bypass that by latching the shadow page directly on F11. If ROM0's handler misbehaves without the flag, revisit (may need a fake flag byte at a TBD address).
- **Turbo+ / GMX** variants: out of scope.
- **Contention approximation**: see §4 ula.sv note.
