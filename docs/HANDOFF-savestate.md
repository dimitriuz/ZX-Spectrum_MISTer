# Savestate (save side): starting prompt for a new session

Open work. Paste the block below into a fresh session, or read it as a briefing.
Loading a snapshot already works in this core; saving one does not.

---

Investigate and, if viable, implement savestate (save-side) for the ZX-Spectrum
MiSTer core in this repo. Loading already works; saving does not.

Work on branch `scorpion-zs256`. Read `AGENTS.md`, `docs/fuse-harness.md` and
`docs/hardware-testing.md` before starting — the last session's tooling is why the
previous bug got solved, and it applies here too.

## Goal

Write the current machine state to a file the core can already load back:
`.z80` v3 (preferred — the loader's own field map is the spec, and it carries the
`#1FFD` byte the Scorpion needs) or `.sna` 128K (simpler, fixed layout, no
compression). An internal format is the fallback, but only worth it if you also
want exact device state, which is a much bigger job.

## Already established - do not re-derive

- `T80pa` exports the full Z80 state on `REG[211:0]`: IFF2, IFF1, IM, IY, HL',
  DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A. It is already wired in the
  top level as `cpu_reg` (`ZX-Spectrum.sv:338`, `.REG` at `:363`) and currently
  only two fields are used (`reg_DE`, `reg_A`). Getting registers out of the CPU
  is free.
- The restore direction is in production: `DIR`/`DIRSet` is how
  `rtl/snap_loader.sv` (622 lines) puts them back. It parses `.z80` and `.sna`
  including `ARCH_SCORP` (hw=10) and `snap_1ffd`. Snapshots arrive at
  `ioctl_index[4:0]==4`, with `.snap_sna(|ioctl_index[7:6])` selecting the format.
- `sys/hps_io.sv` has a complete upload path: `ioctl_upload`,
  `ioctl_upload_req`, `ioctl_upload_index`, `ioctl_din`, `ioctl_rd`. The core
  instantiates `hps_io` directly (`ZX-Spectrum.sv:268`) and simply does not
  connect those five ports — it wires only
  `ioctl_download`/`index`/`wait`/`addr`/`dout`/`wr`.
- Snapshot formats carry CPU + RAM + paging + border and nothing else: no AY
  registers, no ULA counters, no WD1793, no tape position. Accept that or choose
  an internal format deliberately.

## Answer this first - it decides whether this is a core-only change

`sys/hps_io.sv` comments `ioctl_upload_req` with *"must be supported on HPS side
for specific core"*. Read MiSTer-devel/Main_MiSTer and establish exactly what the
HPS does on an upload request: which file it writes to, whether it can create a
new one, and whether any per-core registration is needed. If it can only write
back to the file loaded at that index, the UX is "select a target `.z80`, then
save over it", and that constrains the design. **Do not start writing RTL before
this is answered with a source reference.**

## Then

1. Wire the four upload ports through to the core.
2. Write the mirror of `snap_loader`: assemble the header from `cpu_reg` +
   `page_reg` + `scorp_1ffd` + border, then stream RAM out through `ioctl_din`.
   Uncompressed `.z80` blocks — do not write an RLE encoder.
3. RAM readback needs SDRAM arbitration against the CPU; the loader already owns
   `snap_addr`/`snap_wr` during a load, so mirror that pattern.

## Verify

Round-trip is the test: save a state, load it back into this core, and load the
same file in Fuse 1.7 (`docs/fuse-harness.md` builds an instrumented one that runs
headless and can diff paging behaviour). A file this core writes that Fuse
refuses is a bug in the writer.

## Build and hardware

`tools/build.sh --skip-sim` (always `--skip-sim`; `sim/` is retired). Quartus
rewrites `LAST_QUARTUS_VERSION` in the `.qsf` every build — `git checkout --
ZX-Spectrum.qsf` afterwards, it must never appear in a commit. The DE10-Nano is
at `192.168.1.29` root/`1`; `tools/shot2.sh` drives it over ssh (`ctrl+f11` =
warm reset, `F11` = Shadow Monitor even from a hung CPU). Setting the machine in
the OSD and mounting a disk still need a human.

## Constraints

Keep everything gated so machines 0-4 are unaffected. `scorpion-zs256-pr` is the
upstream PR branch — one commit, no debug scaffolding, no `.qsf`; do not put
work-in-progress there.

---

## Two caveats on the plan itself

- The Main_MiSTer question is a genuine gate, not a formality. If the HPS can only
  overwrite an already-loaded file, the feature's shape changes before any RTL is
  written.
- "Savestate" in the MiSTer sense — exact resume, as the NES/SNES cores do it — is
  **not** what a `.z80` gives you. If that is what is actually wanted, every
  peripheral has to expose and accept its state, and the effort is several times
  larger. Decide which of the two this is before designing.
