# Driving the DE10-Nano over ssh

The MiSTer is the only real verification path (`AGENTS.md`), and almost all of it
can be scripted: load a core, type on the Spectrum, take a screenshot, read it
back. What is left for a human is the OSD - selecting the machine and mounting a
disk - because `/dev/MiSTer_cmd` has no command for either.

MiSTer at `192.168.1.29`, root/`1`. Helpers in `tools/`:

| | |
|---|---|
| `sshrun.py` | ssh/scp with the password over a pty (no `sshpass` on this box) |
| `mkeys2.py` | virtual keyboard via `/dev/uinput`; **keep it at `/media/fat/mkeys2.py`**, `/tmp` is wiped |
| `shot2.sh` | inject keys, screenshot, pull the PNG back |
| `scr2png.py` | render a `.scr` (from the Fuse harness) as a PNG |

```bash
python3 tools/sshrun.py scp releases/ZX-Spectrum_YYYYMMDD.rbf root@192.168.1.29:/media/fat/_Computer/
python3 tools/sshrun.py ssh root@192.168.1.29 "echo load_core /media/fat/_Computer/ZX-Spectrum_YYYYMMDD.rbf > /dev/MiSTer_cmd"

tools/shot2.sh ctrl+f11 sleep:18 enter sleep:16          # reset, pick "128 TR-DOS"
tools/shot2.sh "type:print in 31472" sleep:1 enter sleep:2
```

`shot2.sh` passes its arguments to `mkeys2.py`: named keys (`enter`, `f11`,
`down`, `bs`, …), chords (`ctrl+f11`), `type:<string>` for literal text, and
`sleep:<seconds>`. `HOLD`/`GAP` (default 0.25 s / 0.35 s) set the key timing.

## Keys that matter

| | |
|---|---|
| `ctrl+f11` | **warm reset** - back to the Scorpion boot menu, RAM and the debug capture intact |
| `f11` | MNI - breaks into the Shadow Monitor, even from a hung machine |
| `alt+f11` | cold reset |
| `f10` | reset, but it also latches `#7FFD` bit 4 (`page_reg[4] <= Fn[10]`), so the Scorpion comes up on ROM1 and never reaches its boot menu - use `ctrl+f11` |
| `down` / `up` | boot-menu navigation (Caps+6/7 on the Spectrum matrix) |

Boot to the menu takes ~12 s of emulated time; allow `sleep:18` after a reset.

## Reading state out of a hung machine

**F11 breaks into the Shadow Monitor from anywhere**, and `M. Monitor` shows the
interrupted CPU: PC, SP, all register pairs with the four bytes at each, the
paged RAM/ROM/screen banks, and a dump of `#0000`. That single screenshot is
usually worth more than a rebuild - it is what identified the `#0237` spin. Its
"Enter command" prompt has a parser but the command names are unknown; `help`
hangs the monitor.

Screenshots are 344x284 PNGs. To read small text, decode and upscale a crop
rather than squinting at the whole frame:

```python
# see the crop helper used in docs/fuse-harness.md workflows
crop(30, 35, 320, 120, 3, 'regs_top.png')
```

## Gotchas learned the hard way

- **F12 does not open the OSD** from the virtual keyboard - MiSTer only accepts
  the menu key from an assigned device. Anything behind the OSD needs a human.
- **Keys need a ~0.25 s hold**; the ROM polls at 50 Hz and a 12 ms tap is missed.
- **Quote arguments through ssh.** `shot2.sh` uses `printf '%q '`; an unquoted
  `type:print in 31472` splits at the spaces and `mkeys2.py` dies on the second
  word, silently truncating the line to `print`.
- **`load_core` drops the disk mount** (the machine selection has survived it).
  There is no mount command, so the user has to re-mount.
- **`boot.rom` only refreshes on a full MiSTer reboot**, not on `load_core`.
- The Scorpion's **128 BASIC types keywords letter by letter**; `print in 31472`
  works as typed. After a crash the machine can fall back to 48 BASIC K-mode,
  where the first letter expands to a keyword - `ctrl+f11` and re-select.
- Quartus rewrites `LAST_QUARTUS_VERSION` in the `.qsf` every build - always
  `git checkout -- ZX-Spectrum.qsf` afterwards.
- Build with `setsid nohup docker run ...`; the harness's memory watchdog kills
  managed background tasks mid-compile.

## A process note

The "128 TR-DOS" bug cost two sessions. Roughly ten fixes were proposed from
reading emulator source; two were right and three caused regressions. Every real
advance came from a measurement, and the last one came from being able to
*reproduce the bug in the reference* - see `fuse-harness.md`. Guess in Fuse,
where a hypothesis costs seconds; only build the core once the reference agrees.

And validate the fixture before trusting a result. A blank TRD with no boot
file, a `boot.rom` that had not actually been reloaded, and a debug capture
contaminated by an earlier successful run each produced a confident but wrong
conclusion.
