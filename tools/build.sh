#!/usr/bin/env bash
# Build the ZX-Spectrum MiSTer core for DE10-Nano (Cyclone V 5CSEBA6U23I7).
#
# Pipeline:
#   1. Sim verification gate: full battery + regression diff (AGENTS.md gates 1-2)
#   2. Multi-driver pre-scan (catches Quartus Error 10028 before a 12-min compile)
#   3. Quartus Prime 17.0.2 Lite compile in Docker (raetro/quartus:17.0)
#   4. Stage releases/ZX-Spectrum_YYYYMMDD.rbf + print fitter summary
#   5. Verify releases/boot.rom (size + Scorpion pages) and print SHA256
#
# Usage:
#   tools/build.sh                       # full pipeline (~40 min: 25 sim + 12 compile)
#   tools/build.sh --skip-sim            # skip the sim gate (e.g. docs-only changes)
#   tools/build.sh --skip-quartus        # no compile; re-stages existing output_files rbf
#   tools/build.sh --rebuild-rom FILE    # rebuild boot.rom from a 192KB upstream base ROM
#   tools/build.sh --rebuild-rom upstream
#                                        # fetch current upstream master boot.rom as base
#
# After any --rebuild-rom: update the SHA256 line in README.md and commit both files.
set -euo pipefail
cd "$(dirname "$0")/.."

QUARTUS_IMAGE="raetro/quartus:17.0"
SKIP_SIM=0
SKIP_QUARTUS=0
REBUILD_ROM=""

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-sim)     SKIP_SIM=1; shift ;;
        --skip-quartus) SKIP_QUARTUS=1; shift ;;
        --rebuild-rom)  shift; REBUILD_ROM="${1:?--rebuild-rom needs FILE or 'upstream'}"; shift ;;
        *) echo "unknown argument: $1 (see header)" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. sim gate
if [ "$SKIP_SIM" = 0 ]; then
    step "1/5 sim verification gate (battery + regression diff)"
    for t in smoke regression alias paging romchain mni snapscorp; do
        printf -- "--- %s\n" "$t"
        if ! ./sim/run_sim.sh "$t" | grep -E "PASS|FAIL"; then
            echo "GATE FAILED: test $t did not report PASS" >&2
            exit 1
        fi
    done
    diff sim/out/regression_base.txt sim/out/regression_new.txt
    echo "regression diff: byte-clean"
else
    step "1/5 sim verification gate (skipped)"
fi

# ------------------------------------------------- 2. multi-driver pre-scan
step "2/5 multi-driver pre-scan (Quartus Error 10028 guard)"
if ! python3 tools/multidriver_scan.py ZX-Spectrum.sv rtl/*.sv rtl/*.v sys/*.sv sys/*.v; then
    echo "multi-driver hits found — fix before compiling (see scanner output)" >&2
    exit 1
fi

# ---------------------------------------------------------- 3. quartus build
if [ "$SKIP_QUARTUS" = 0 ]; then
    step "3/5 Quartus compile ($QUARTUS_IMAGE -> 5CSEBA6U23I7)"
    if ! docker image inspect "$QUARTUS_IMAGE" >/dev/null 2>&1; then
        echo "pulling $QUARTUS_IMAGE (~6 GB, first time only)..."
        docker pull "$QUARTUS_IMAGE"
    fi
    docker run --rm -v "$PWD":/work -w /work "$QUARTUS_IMAGE" \
        bash -lc "/opt/intelFPGA/quartus/bin/quartus_sh --flow compile ZX-Spectrum"
else
    step "3/5 Quartus compile (skipped)"
fi

# ------------------------------------------------------------- 4. stage rbf
step "4/5 stage firmware"
[ -f output_files/ZX-Spectrum.rbf ] || { echo "missing output_files/ZX-Spectrum.rbf — did the compile run?" >&2; exit 1; }
DATE=$(date +%Y%m%d)
cp output_files/ZX-Spectrum.rbf "releases/ZX-Spectrum_${DATE}.rbf"
ls -l "releases/ZX-Spectrum_${DATE}.rbf"
grep -E "Fitter Status|Quartus Prime Version|Device|Logic utilization" output_files/ZX-Spectrum.fit.summary

# ---------------------------------------------------------- 5. boot.rom check
step "5/5 boot.rom"
if [ -n "$REBUILD_ROM" ]; then
    BASE=""
    if [ "$REBUILD_ROM" = "upstream" ]; then
        BASE=$(mktemp)
        curl -fsSL "https://raw.githubusercontent.com/MiSTer-devel/ZX-Spectrum_MISTer/master/releases/boot.rom" -o "$BASE"
    else
        BASE="$REBUILD_ROM"
    fi
    python3 tools/build_boot_rom.py --base "$BASE" -o releases/boot.rom
    [ "$REBUILD_ROM" = "upstream" ] && rm -f "$BASE"
    echo "!! boot.rom changed — update the SHA256 line in README.md and commit both files."
else
    python3 tools/build_boot_rom.py --check releases/boot.rom
fi

step "done"
echo "SD card:  rbf -> <sd>/          (MiSTer root)"
echo "          boot.rom -> <sd>/games/Spectrum/"
