# AGENTS.md — ZX-Spectrum MiSTer core

Working guide for agents (and humans) in this repository.

## What this is

SystemVerilog/Quartus FPGA core of the ZX Spectrum family for MiSTer. Branch
`scorpion-zs256` adds the Scorpion ZS-256 machine (machine #5). All changes are
verified sim-first with the iverilog harness in `sim/`; Quartus builds happen
only after sim is green.

## Workflow rules

- **Do all calculations by scripts** (python3, awk, xxd — anything that runs): hex decoding, bit-field math, address/SDRAM mapping, ROM scans/disassembly, checksums. Never compute these in your head; write a script, run it, trust its output.
- **Do not use subagents.** Work directly in the current session: read, edit, run sim, iterate. This repo's work is a tight sim-debug loop — delegation adds overhead without useful parallelism.

## Repo layout

| Path | Contents |
|---|---|
| `ZX-Spectrum.sv` | Top level: machine select, ULA port, paging decode, SDRAM address mapping |
| `rtl/` | Machine blocks (`ula`, `sdram`, `snap_loader`, `keyboard`, `ym2149`, `wd1793`, `u765`, `jt12/`, `tape`) |
| `sys/` | MiSTer system blocks (`video_mixer`, `hq2x`) |
| `tools/` | ROM build scripts; `scorp294.rom` = Scorpion v2.94 source pages |
| `releases/boot.rom` | 256 KB generated boot image — rebuild with `tools/build_boot_rom.py` (SHA-verified) |
| `docs/scorpion-zs256-design.md` | Authoritative Scorpion reference: hardware semantics, decisions, limitations |
| `sim/` | Iverilog testbench harness — not part of the FPGA build |

## Sim pipeline (primary verification path)

- Docker image `xzs-sim:1.0` (Arch Linux, iverilog v12, `-g2012`).
  **iverilog rejects `-O` entirely** — no optimization flags exist.
- Run tests: `./sim/run_sim.sh <test>` where test is one of
  `smoke | regression | alias | paging | romchain | mni | snapscorp | boot`.
- Default CPU is a fetch-only stub (`sim/t80_stub.v`) — fast; verifies
  decode/memory/paging without executing code.
- `REALCPU=1 ./sim/run_sim.sh boot` compiles TV80 (open-source Z80 in
  `sim/cpu/`, permissive license) as `T80pa` and executes real v2.94 code.
- Outputs land in `sim/out/` (gitignored except `regression_base.txt`).

Speeds — plan test windows accordingly:

| CPU | Speed | Example |
|---|---|---|
| stub | ~7.5x slower than real time | full battery ≈ 25 min |
| REALCPU (TV80) | ~22,000x slower (~5k core clocks/s measured) | 1 frame = 2,236,416 core clocks ≈ 7.5 min wall |

Use early exit in long tests; the boot test exits when v2.94's post-init paging
state (#7FFD=0x10/#1FFD=0x12) is reached (i≈95M core clocks ≈ 4.5 h wall on this host).

**Gates before committing any RTL change:**

1. Full battery green: smoke, regression, alias, paging, romchain, mni, snapscorp
2. `diff sim/out/regression_base.txt sim/out/regression_new.txt` → byte-clean
3. Scorpion behavior changes: REALCPU boot test as well
4. **Coverage caveat:** the regression trace captures CPU/memory state only —
   NOT audio or video output. Any conversion of sound-module tables (saa1099,
   ym2149) or palette/LUT code MUST be verified value-by-value against the
   original with a script (all indices × all inputs), not just by the battery.

## Quartus build (FPGA firmware)

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

- **No behavior change to existing machines (0–4).** The regression trace diff
  is the gate; if a change must affect them, get explicit approval and
  re-baseline `regression_base.txt`. Scorpion is machine #5
  (`status[12:10] == 5`).
- `border_color` in `ZX-Spectrum.sv` is initialized to `3'b000`: FPGA
  flip-flops power up at 0, and Scorpion v2.94 never writes port #FF during
  boot, so the init is load-bearing for Scorpion. Do not revert.
- **Never add per-core-clock SDRAM reads from the testbench.** Bus-side
  sampling contends with the CPU's bursty traffic and slows REALCPU sim
  20–30x (watchdog hangs). To inspect memory, use `sdr_byte()` in
  `sim/tb_top.sv` — a hierarchical read of the SDRAM model array
  (`sdr.mem[la[23]][{la[13:1], la[19:14]}]`, byte select `la[0]`), zero bus
  traffic, sampled at most once per core clock.
- Scorpion paging decode must match Fuse `scorp_fuse.c` / speccy-bootcamp:
  - CPU #4000–#7FFF **fixed to physical bank 5**; #8000–#BFFF fixed to bank 2
    (unlike the ZX128 — verified against speccy-bootcamp).
  - `#7FFD` bit 3 selects the **ULA video source** only (bank 5 vs bank 7
    dpram mirror), not the CPU decode.
  - ROM at #0000: `#1FFD[0]` → RAM bank 0; else `#1FFD[1]` → ROM2 (Shadow
    Monitor); else `#7FFD[4]` ? ROM1 : ROM0.
  - Paged bank at #C000: `scorp_page = {#1FFD[4], #7FFD[2:0]}` (bank b = SDRAM
    column b).
  - `#7FFD` bit-5 lockout blocks further paging writes until reset (the locking
    write itself applies).
- `scorp_1ffd` has exactly one driver (io_wr or the `mni_pending` latch) — keep
  it single-driver. MNI = F11: sets bit 1 + pulses NMI → Shadow Monitor at #0066.

## Measured Scorpion v2.94 boot behavior (real CPU, for test design)

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
screen content as informational and pins the display write path in test_paging.

## Branch state

`scorpion-zs256` (forked from master `7510bb2`, pushed to `dimitriuz/ZX-Spectrum_MISTer`): complete Scorpion ZS-256 support —
decode/paging/ROM window, MNI via F11, snapshots (z80 hw=10, ARCH_SCORP),
real-CPU boot verification. Not yet merged to main; Quartus build not yet run
(sim-first policy — review the diff before any Quartus build).
