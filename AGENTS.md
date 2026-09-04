# AGENTS.md — ZX-Spectrum MiSTer core

Working guide for agents (and humans) in this repository.

## What this is

SystemVerilog/Quartus FPGA core of the ZX Spectrum family for MiSTer. Branch
`scorpion-zs256` adds the Scorpion ZS-256 machine (machine #5). Changes are verified by
building with Quartus and running on a DE10-Nano — see "Verification path" below.

## Workflow rules

- **Do all calculations by scripts** (python3, awk, xxd — anything that runs): hex decoding, bit-field math, address/SDRAM mapping, ROM scans/disassembly, checksums. Never compute these in your head; write a script, run it, trust its output.
- **Do not use subagents** for the edit/build loop — it is tight and sequential, and delegation adds overhead without useful parallelism. (A one-shot review pass over a finished diff is fine.)

## Repo layout

| Path | Contents |
|---|---|
| `ZX-Spectrum.sv` | Top level: machine select, ULA port, paging decode, SDRAM address mapping |
| `rtl/` | Machine blocks (`ula`, `sdram`, `snap_loader`, `keyboard`, `ym2149`, `wd1793`, `u765`, `jt12/`, `tape`) |
| `sys/` | MiSTer system blocks (`video_mixer`, `hq2x`) |
| `tools/` | ROM build scripts; `scorp294.rom` = Scorpion v2.94 source pages |
| `releases/boot.rom` | 256 KB generated boot image — rebuild with `tools/build_boot_rom.py` (SHA-verified) |
| `docs/scorpion-zs256-design.md` | Authoritative Scorpion reference: hardware semantics, decisions, limitations |
| `sim/` | Retired iverilog harness — reference only, does not compile (see below) |

## Verification path: hardware

The iverilog harness in `sim/` is **retired**. It only ever compiled because a set of
"behavior-preserving" portability patches had been applied to `rtl/` and `sys/`
(unpacked-array ports, assignment-pattern initialisers, `inout reg`). Those patches have
been reverted — they were churn in files the Scorpion feature does not touch, and two of
them were not behavior-preserving at all:

- `sys/video_mixer.sv` gained a width bug in the `HALF_DEPTH && !GAMMA` path (latent
  here, live for any core that uses it).
- `rtl/u765.sv` moved `image_ready`'s **power-on** initialiser into the **reset** block.
  Nothing restored it (the "restart mounting" guard only fires when a scan is already in
  flight), so any reset — OSD Reset, F10, F11+mod, VHD mount — permanently marked a
  mounted +3 floppy not-ready until remount.

Lesson worth keeping: `reg x[2] = '{0,0};` is a power-up value, not a reset value; moving
one into `if(reset)` changes behavior. And a CPU/memory regression trace cannot catch a
regression in the FDC, the audio LUTs or the video path — scope your gate to what it
actually observes.

The files under `sim/` are left in the tree for reference but **do not compile against the
current RTL**. Verify on the DE10-Nano instead; the hardware test plan is
§5 of `docs/scorpion-zs256-design.md`.

## Quartus build (FPGA firmware)

- **Full pipeline: `tools/build.sh`** (sim gate → multi-driver pre-scan →
  compile → stage rbf → boot.rom check); every step documented in
  `docs/build.md`. Flags: `--skip-sim`, `--skip-quartus`, `--rebuild-rom [FILE|upstream]`.
  **Always pass `--skip-sim`** — the sim gate cannot run any more (see above).
- Toolchain: **Quartus Prime 17.0.2 Lite** via Docker container `raetro/quartus:17.0`
  (built from Intel's official installer; no license needed for Cyclone V).
  The version matters: `sys/sys.qip` selects the PLL QIP by toolchain version
  (`pll_q<ver>.qip`) — the repo ships `pll_q13.qip` + `pll_q17.qip`, so build with
  17.x (or 13.1 via `ZX-Spectrum_Q13.qpf`). The official Intel container
  (`alterafpga/quartus-std`) requires a subscription license — do not use it.
- Build: `docker run --rm -v "$PWD":/work -w /work raetro/quartus:17.0 bash -lc "/opt/intelFPGA/quartus/bin/quartus_sh --flow compile ZX-Spectrum"`
  (~12 min on 16 cores; target 5CSEBA6U23I7 = DE10-Nano).
- Output: `output_files/ZX-Spectrum.rbf` (`GENERATE_RBF_FILE ON`) → copy to
  `releases/` as `ZX-Spectrum_YYYYMMDD.rbf`. Reference timing of the 2026-09-03
  build: worst setup slack +0.233 ns, hold +0.183 ns @ 50 MHz.
- **iverilog vs Quartus:** Icarus silently accepts multiple `always` blocks
  driving one reg; Quartus rejects it (Error 10028). Keep one driver per reg —
  run `python3 tools/multidriver_scan.py ZX-Spectrum.sv rtl/*.sv rtl/*.v sys/*.sv sys/*.v`
  before building (known false positive: relational comparisons like `(a <= b)`).


## Invariants (do not break)

- **No behavior change to existing machines (0–4).** Scorpion is machine #5
  (`status[12:10] == 5`); everything Scorpion-specific is gated on the `scorp` flag.
  Touch shared paths only when there is no gated alternative, and say so explicitly.
  Never modify `sys/` — it is MiSTer framework code, synced from Template_MiSTer.
- `border_color` in `ZX-Spectrum.sv` is initialized to `3'b000`: FPGA
  flip-flops power up at 0, and Scorpion v2.94 never writes port #FF during
  boot, so the init is load-bearing for Scorpion. Do not revert.
- Scorpion paging decode must match Fuse `scorp_fuse.c` / speccy-bootcamp:
  - CPU #4000–#7FFF **fixed to physical bank 5**; #8000–#BFFF fixed to bank 2
    (unlike the ZX128 — verified against speccy-bootcamp).
  - `#7FFD` bit 3 selects the **ULA video source** only (bank 5 vs bank 7
    dpram mirror), not the CPU decode.
  - ROM at #0000: `#1FFD[0]` → RAM bank 0; else `#1FFD[1]` → ROM2 (Shadow
    Monitor); else `#7FFD[4]` ? ROM1 : ROM0.
  - Paged bank at #C000: `scorp_page = {#1FFD[4], #7FFD[2:0]}`; RAM bank b sits at
    logical address `b*0x4000`.
  - Scorpion ROM window is `{3'b110, page_rom, addr[13:0]}` = `0x180000 + p*0x4000`,
    which is exactly boot.rom offset `0x30000 + p*0x4000` (load base `0x150000`).
    The SDRAM controller decodes all 25 bits — there is no aliasing to exploit.
  - `#7FFD` bit-5 lockout blocks further **#7FFD** writes until reset (the locking
    write itself applies). `#1FFD` is *not* locked — locking it would trap the machine
    in the Shadow Monitor, whose exit is a #1FFD write.
- `scorp_1ffd` has exactly one driver (io_wr or the `mni_pending` latch) — keep
  it single-driver. MNI = F11: sets **bit 1 only** (preserve bit 4 = `scorp_page[3]`,
  or entering the monitor silently repages #C000) + pulses NMI → Shadow Monitor at #0066.
- DivMMC is forced off in Scorpion mode (`mmc_mode <= 0`): `mmc_ram_en` outranks the ROM
  decode, so leaving it on pages DivMMC RAM in at #2000–#3FFF while its ROM can never be
  selected.

## Measured Scorpion v2.94 boot behavior (from the retired TV80 sim — reference for what to expect on hardware)

Boot flow (i = core clocks; T-state = 32 core clocks): ROM0 init + long DEC BC
countdowns → post-init at i≈29M (~260 ms machine time) sets `#1FFD=0x12`
(Shadow Monitor select) and counts `#7FFD` down 0x17→0x16→…→0x10, one step per
~1.1M core clocks (~98 ms), stopping at the **final state #7FFD=0x10,
#1FFD=0x12** at i≈95M (~850 ms machine time). The CPU then runs from paged RAM /
ROM2 (no more M1 fetches from the ROM0 window). ULA INT spacing is exactly one
frame (69,888 T-states = 2,236,416 core clocks = 20 ms). Border stays 0 for the
whole boot (no #FF write until TR-DOS is entered). **Unattended boot does not
draw a visible screen** — the only display-file writes are three scratch bytes
(vram offsets 0x1C1B-0x1C1D, beyond the visible 24-band region); the Shadow
Monitor draws its UI only on user interaction. The boot test therefore treats
screen content as informational — do not expect a banner from an unattended boot.

## Branch state

`scorpion-zs256` — working branch: the Scorpion feature plus local tooling, docs, the
retired `sim/` tree and a staged `.rbf`.

`scorpion-zs256-pr` — the upstream PR branch: `ZX-Spectrum.sv`, `rtl/snap_loader.sv`,
`README.md`, `docs/scorpion-zs256-design.md`, `releases/boot.rom`,
`tools/build_boot_rom.py`, `tools/scorp294.rom` and nothing else. Rebase this one onto
upstream master before opening the PR.

Not yet flashed to hardware — run §5 of the design doc before opening the PR.
