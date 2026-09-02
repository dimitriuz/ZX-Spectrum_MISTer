# AGENTS.md — ZX-Spectrum MiSTer core

Working guide for agents (and humans) in this repository.

## What this is

SystemVerilog/Quartus FPGA core of the ZX Spectrum family for MiSTer. Branch
`scorpion-zs256` adds the Scorpion ZS-256 machine (machine #5). All changes are
verified sim-first with the iverilog harness in `sim/`; Quartus builds happen
only after sim is green.

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
| REALCPU (TV80) | ~1350x slower | 480 ms machine window ≈ 11 min wall |

Use early exit in long tests; the boot test exits at its first criteria poll
(~6 min wall).

**Gates before committing any RTL change:**

1. Full battery green: smoke, regression, alias, paging, romchain, mni, snapscorp
2. `diff sim/out/regression_base.txt sim/out/regression_new.txt` → byte-clean
3. Scorpion behavior changes: REALCPU boot test as well

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
  (`sdr.mem[bank][row]`), zero bus traffic, sampled at most once per core clock.
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

BC=0xFFFF countdown (~800 ms machine time) → post-init code sets paging
(`#7FFD=16`, `#1FFD=12` = upper page + Shadow ROM select) → CPU lives in the
Shadow Monitor area. ULA INT spacing is exactly one frame (140k T-states).
Border stays 0 for the whole boot (no #FF write until TR-DOS is entered).

## Branch state

`scorpion-zs256` (`b95fc83..b7cdafa`): complete Scorpion ZS-256 support —
decode/paging/ROM window, MNI via F11, snapshots (z80 hw=10, ARCH_SCORP),
real-CPU boot verification. Not yet merged to main; Quartus build not yet run
(sim-first policy — review the diff before any Quartus build).
