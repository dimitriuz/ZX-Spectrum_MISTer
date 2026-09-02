#!/usr/bin/env bash
# Compile + run the Icarus Verilog simulation in Docker (image xzs-sim:1.0, see sim/Dockerfile).
# Usage: ./sim/run_sim.sh [testname] [stop-ns] [regfile]
#   testname  TB test to run (default: smoke); passed as +TEST=<name>
#   stop-ns   watchdog in sim-time ns (default: 300000000 = 300 ms; download-based tests need >20 ms); passed as +STOPNS=<n>
#   regfile   output file for the regression test (default: sim/out/regression_new.txt)
set -euo pipefail
cd "$(dirname "$0")/.."

TEST="${1:-smoke}"
STOPNS="${2:-300000000}"
REGFILE="${3:-sim/out/regression_new.txt}"

# REALCPU=1 swaps the fetch-only CPU stub for a real Z80 (TV80) - boot test only.
CPU_FILES="sim/t80_stub.v"
if [ "${REALCPU:-0}" = "1" ]; then
    CPU_FILES="sim/cpu/t80_real.v sim/cpu/tv80/tv80s.v sim/cpu/tv80/tv80_core.v sim/cpu/tv80/tv80_alu.v sim/cpu/tv80/tv80_mcode.v sim/cpu/tv80/tv80_reg.v"
fi

# jt12's $readmemh uses bare filenames resolved against CWD - stage them at repo root
cp rtl/jt12/lfo_sh1_lut.hex rtl/jt12/lfo_sh2_lut.hex .
trap 'rm -f lfo_sh1_lut.hex lfo_sh2_lut.hex' EXIT
docker run --rm -v "$PWD":/work -w /work xzs-sim:1.0 bash -c "
  set -e
  mkdir -p sim/out
  iverilog -g2012 -o sim/work.vvp \
      -I sim \
      sim/build_id.v \
      sim/prims/altddio_out.v sim/prims/pll_model.v sim/prims/altsyncram_model.v sim/prims/sys_math_models.v \
      sim/sdram_model.v sim/host_model.v ${CPU_FILES} sim/tzxplayer_stub.v \
      sim/tb_top.sv \
      ZX-Spectrum.sv rtl/gs.v rtl/divmmc.v rtl/dpram.v \
      sys/sd_card.sv sys/video_freak.sv sys/video_mixer.sv sys/ltc2308.sv \
      rtl/sdram.sv rtl/saa1099.sv rtl/turbosound.sv rtl/ym2149.sv rtl/snap_loader.sv \
      rtl/wd1793.sv rtl/u765.sv rtl/ddram.sv rtl/ula.sv rtl/tape.sv rtl/mouse.v rtl/keyboard.sv \
      rtl/jt12/jt03.v rtl/jt12/jt03_acc.v \
      rtl/jt12/jt12_top.v rtl/jt12/jt12_single_acc.v rtl/jt12/jt12_pm.v rtl/jt12/jt12_reg.v \
      rtl/jt12/jt12_sh.v rtl/jt12/jt12_sh24.v rtl/jt12/jt12_sh_rst.v rtl/jt12/jt12_sumch.v \
      rtl/jt12/jt12_timers.v rtl/jt12/jt12_csr.v rtl/jt12/jt12_div.v rtl/jt12/jt12_eg.v \
      rtl/jt12/jt12_eg_cnt.v rtl/jt12/jt12_eg_comb.v rtl/jt12/jt12_eg_ctrl.v rtl/jt12/jt12_eg_final.v \
      rtl/jt12/jt12_eg_pure.v rtl/jt12/jt12_eg_step.v rtl/jt12/jt12_exprom.v rtl/jt12/jt12_kon.v \
      rtl/jt12/jt12_lfo.v rtl/jt12/jt12_limitamp.v rtl/jt12/jt12_logsin.v rtl/jt12/jt12_mmr.v \
      rtl/jt12/jt12_mod.v rtl/jt12/jt12_op.v rtl/jt12/jt12_pcm.v rtl/jt12/jt12_pg.v \
      rtl/jt12/jt12_pg_comb.v rtl/jt12/jt12_pg_dt.v rtl/jt12/jt12_pg_inc.v rtl/jt12/jt12_pg_sum.v \
      sys/scandoubler.v sys/video_freezer.sv sys/gamma_corr.sv sys/hq2x.sv \
      2> sim/compile_err.log || { echo 'COMPILE FAILED:'; cat sim/compile_err.log; exit 1; }
  vvp sim/work.vvp +TEST=${TEST} +STOPNS=${STOPNS} +REGFILE=${REGFILE}
"
