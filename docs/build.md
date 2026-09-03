# Building the ZX-Spectrum MiSTer core

Complete build procedure for the DE10-Nano firmware (Cyclone V **5CSEBA6U23I7**)
and the Scorpion-extended boot ROM. Everything is scriptable:

```bash
tools/build.sh          # full pipeline: sim gate -> pre-scan -> compile -> stage -> rom check
```

Manual steps below are what the script runs, for when you need to do one stage
or debug a failure.

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker | any modern version; the Quartus image is ~6 GB |
| `raetro/quartus:17.0` image | pulled automatically by `tools/build.sh` on first use |
| Disk | ~10 GB (image + `db/`, `incremental_db/`, `output_files/` build dirs, all gitignored) |
| RAM / cores | 16 GB / 8+ cores comfortable; reference build used 16 cores, ~12 min wall |
| Python 3 | for `tools/build_boot_rom.py` and `tools/multidriver_scan.py` |

## Stage 1 — Sim verification gate

The sim-first policy (AGENTS.md): the iverilog battery must be green before any
Firmware build ships.

```bash
for t in smoke regression alias paging romchain mni snapscorp; do ./sim/run_sim.sh $t; done
diff sim/out/regression_base.txt sim/out/regression_new.txt   # must be byte-clean
```

~25 min on the reference host. Scorpion behavior changes additionally require
the REALCPU boot test (`REALCPU=1 ./sim/run_sim.sh boot`, ~4.5 h, early exit).

## Stage 2 — Multi-driver pre-scan

iverilog silently accepts multiple `always` blocks driving one reg; Quartus
rejects it at elaboration with **Error (10028)** and you lose a compile cycle
finding out. Run the scanner before building:

```bash
python3 tools/multidriver_scan.py ZX-Spectrum.sv rtl/*.sv rtl/*.v sys/*.sv sys/*.v
```

Text heuristic, per-module scope. Known dismissed false positive: `vc_next` in
`rtl/ula.sv` (relational comparison `(vc_next <= 307)`, single real driver).
Any other hit must be fixed or explicitly dismissed before compiling.

## Stage 3 — Quartus compile

### Toolchain: why exactly Quartus Prime 17.0.2 Lite

- `sys/sys.qip` selects the PLL megafunction QIP **by toolchain version**:
  `pll_q<version>.qip`. The repo ships `sys/pll_q13.qip` and `sys/pll_q17.qip` —
  building with any other major version warns "Tcl Script File sys/pll_qNN.qip
  not found" and compiles without the intended PLL QIP. **Use 17.x** (or 13.1
  with the legacy `ZX-Spectrum_Q13.qpf`).
- The official Intel container (`alterafpga/quartus-std`) is Standard Edition
  and fails with `Error (292025): License file is not specified` — it requires
  a subscription license. The `raetro/quartus:17.0` image is built from Intel's
  official **Lite** installer; Cyclone V is a free Lite family, no license needed.

### Command

```bash
docker pull raetro/quartus:17.0   # first time only (~6 GB)
docker run --rm -v "$PWD":/work -w /work raetro/quartus:17.0 \
    bash -lc "/opt/intelFPGA/quartus/bin/quartus_sh --flow compile ZX-Spectrum"
```

Full flow (analysis & synthesis → fitter → assembler → TimeQuest) in ~12 min on
16 cores. `GENERATE_RBF_FILE ON` in the .qsf makes Quartus emit the SD-card-ready
`.rbf` directly — no post-processing.

### Reference results (2026-09-03 build, commit 717d085)

| Metric | Value |
|---|---|
| Compilation | successful, 0 errors, 28 benign warnings¹ |
| Worst setup slack @ 50 MHz | +0.233 ns |
| Worst hold slack | +0.183 ns |
| ALMs | 22,023 / 41,910 (53 %) |
| Registers | 26,875 |
| Pins | 145 / 314 (46 %) |
| Block memory | 1,726,661 / 5,662,720 bits (30 %) |
| RAM blocks / DSP / PLLs | 226/553 · 39/112 · 3/6 |

¹ Benign set: T80.vhd intentional latch inference, upstream `video_mixer.sv`
truncation notices, fitter assignment warnings. New warnings touching `rtl/` or
`ZX-Spectrum.sv` deserve a look.

## Stage 4 — Staging the firmware

```bash
cp output_files/ZX-Spectrum.rbf releases/ZX-Spectrum_$(date +%Y%m%d).rbf
```

Naming convention: `ZX-Spectrum_YYYYMMDD.rbf`, matching existing releases.
Commit the rbf (it is tracked; `output_files/` and Quartus work dirs are not).

## Stage 5 — boot.rom

`releases/boot.rom` is **256 KB** = 192 KB upstream base ROM + 64 KB Scorpion
v2.94 pages (`tools/scorp294.rom`, chunks 12–15). The core's Scorpion machine
select reads its firmware from those pages — a 192 KB ROM has no Scorpion.

Verify the committed file:

```bash
python3 tools/build_boot_rom.py --check releases/boot.rom
# -> OK + full sha256 (must match the SHA256 line in README.md)
```

Rebuild after an upstream base update or a Scorpion ROM change:

```bash
# from a local 192 KB upstream release ROM:
python3 tools/build_boot_rom.py --base <boot.rom-192k> -o releases/boot.rom
# or fetch the current upstream master base automatically (tools/build.sh):
tools/build.sh --rebuild-rom upstream
```

The base is `releases/boot.rom` from
[MiSTer-devel/ZX-Spectrum_MISTer](https://github.com/MiSTer-devel/ZX-Spectrum_MISTer)
master (the 192 KB file there; our first 192 KB were verified byte-identical to
it on 2026-09-03). After any rebuild: **update the SHA256 line in README.md and
commit `releases/boot.rom` together with it.**

## SD card layout

```
<sd>/                                  # MiSTer root
├── ZX-Spectrum_YYYYMMDD.rbf           # the core firmware
└── games/Spectrum/
    └── boot.rom                       # 256 KB (Scorpion-capable)
```

OSD → **Memory** menu → **Scorpion ZS-256**. F11 enters the Shadow Service
Monitor (MNI).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Error (292025): License file is not specified` | You're in the official `alterafpga/quartus-std` container (Standard Edition, needs subscription). Use `raetro/quartus:17.0`. |
| `Warning (125092): Tcl Script File sys/pll_qNN.qip not found` | Toolchain version ≠ 13/17. Switch to `raetro/quartus:17.0`; the build would silently miss the PLL QIP. |
| `Error (10028): Can't resolve multiple constant drivers for net "X"` | Multi-driver reg — iverilog won't catch this. Run `tools/multidriver_scan.py`, merge the drivers into one always block (single-driver discipline, see the `mni_pending` fix in commit 9e8e7a8). |
| Compile succeeds but no `.rbf` in `output_files/` | `GENERATE_RBF_FILE ON` missing from the .qsf — restore it. |
| `COMPILE FAILED:` from `sim/run_sim.sh` | Iverilog error; full log in `sim/compile_err.log`. |
| Battery test hangs / watchdog | Check `+STOPNS` for the test (download-based tests need >20 ms sim time); never add per-core-clock SDRAM reads to the TB (see AGENTS.md invariants). |

## Legacy: Q13 project

`ZX-Spectrum_Q13.qpf/.qsf` is the same design for Quartus 13.1 (`pll_q13.qip`).
It has no DEVICE assignment — select the target device when building with it.
The current/only supported target is DE10-Nano via `ZX-Spectrum.qpf`.
