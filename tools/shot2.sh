#!/usr/bin/env bash
# usage: shot2.sh [mkeys2 args...]   -> injects keys, screenshots, pulls the PNG
S=$(cd "$(dirname "$0")/.." && pwd)/tools
O="-o StrictHostKeyChecking=no -o ConnectTimeout=8"
mkdir -p ${SHOTS:-${TMPDIR:-/tmp}/mister-shots}
ARGS=$(printf '%q ' "$@")
N=$(timeout 600 python3 $S/sshrun.py ssh $O root@192.168.1.29 \
  "SETTLE=6 HOLD=${HOLD:-0.25} GAP=${GAP:-0.35} python3 /media/fat/mkeys2.py $ARGS >/dev/null 2>&1; sleep 2; timeout 5 sh -c 'echo screenshot > /dev/MiSTer_cmd'; sleep 2; ls -t /media/fat/screenshots/Spectrum/ | head -1" \
  2>&1 | grep -oE '[0-9]{8}_[0-9]{6}-[A-Za-z0-9_.-]+\.png' | head -1)
[ -z "$N" ] && { echo "no screenshot"; exit 1; }
timeout 60 python3 $S/sshrun.py scp $O "root@192.168.1.29:/media/fat/screenshots/Spectrum/$N" ${SHOTS:-${TMPDIR:-/tmp}/mister-shots}/ >/dev/null 2>&1
echo "${SHOTS:-${TMPDIR:-/tmp}/mister-shots}/$N"
