#!/usr/bin/env bash
# run-on-k3.sh - from the build host: boot the board -> run the reproducer -> save the log
#
# usage: ./scripts/run-on-k3.sh <tag> [iters] [cpu0] [cpu1]
#
# needs (override via environment):
#   BOARDCTL  path to boardctl.sh  default ~/work/devboards/boardctl.sh
#   BOARD     board name           default k3
#   TFTP      tftp root            default /srv/tftp
#   SERVERIP  tftp server          default 192.168.19.100
#   DIST      artefacts directory  default <repo>/dist
#   RES       log directory        default <repo>/results
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?usage: run-on-k3.sh <tag> [iters] [cpu0] [cpu1]}
ITERS=${2:-8}
CPU0=${3:-0}
CPU1=${4:-1}

BOARDCTL=${BOARDCTL:-$HOME/work/devboards/boardctl.sh}
BOARD=${BOARD:-k3}
TFTP=${TFTP:-/srv/tftp}
SERVERIP=${SERVERIP:-192.168.19.100}
DIST=${DIST:-$HERE/dist}
RES=${RES:-$HERE/results}
ITB=$DIST/Image-$TAG.itb

[ -f "$ITB" ] || { echo "!! missing $ITB (run pack-fit.sh -t $TAG first)"; exit 2; }
[ -x "$BOARDCTL" ] || { echo "!! missing boardctl: $BOARDCTL"; exit 2; }
mkdir -p "$RES" "$TFTP/$BOARD"
cp -f "$ITB" "$TFTP/$BOARD/"

LOG=$("$BOARDCTL" log "$BOARD" 2>/dev/null | tr -d '\r' | tail -1)
if [ ! -f "$LOG" ]; then
	LOG=$(ls -t /tmp/*"$BOARD"*.log 2>/dev/null | head -1)
fi
[ -f "$LOG" ] || { echo "!! no serial console log file found"; exit 2; }
echo "   console log: $LOG"

wait_for() {	# $1 pattern, $2 timeout, $3 start offset
	local pat=$1 tmo=$2 off=${3:-0} i=0
	while [ "$i" -lt "$tmo" ]; do
		if tail -c +"$off" "$LOG" 2>/dev/null | tr -d '\r' | grep -q -- "$pat"; then
			echo "   [ok] '$pat' after ${i}s"; return 0
		fi
		sleep 2; i=$((i + 2))
	done
	echo "   [TIMEOUT] '$pat' after ${tmo}s"; return 1
}

OFF=$(stat -c%s "$LOG")

echo "== [1/5] power cycle + U-Boot"
"$BOARDCTL" catch "$BOARD" 40 >/dev/null 2>&1
wait_for '=>' 30 "$OFF" || { echo "!! did not catch U-Boot"; exit 3; }
sleep 1
"$BOARDCTL" key "$BOARD" C-c >/dev/null 2>&1
sleep 1

echo "== [2/5] bootargs / watchdog"
"$BOARDCTL" send "$BOARD" "setenv bootargs 'earlycon=sbi console=ttyS0,115200 clk_ignore_unused loglevel=7 no_console_suspend'" >/dev/null 2>&1
sleep 1
"$BOARDCTL" send "$BOARD" 'wdt stop' >/dev/null 2>&1
sleep 1
"$BOARDCTL" send "$BOARD" 'dhcp' >/dev/null 2>&1
wait_for 'DHCP client bound' 45 "$OFF"

echo "== [3/5] tftp + bootm"
"$BOARDCTL" send "$BOARD" "setenv serverip $SERVERIP" >/dev/null 2>&1
sleep 1
"$BOARDCTL" send "$BOARD" "tftpboot 0x140000000 $BOARD/$(basename "$ITB")" >/dev/null 2>&1
wait_for 'Bytes transferred' 180 "$OFF" || { echo "!! tftp failed"; exit 4; }
"$BOARDCTL" send "$BOARD" 'bootm 0x140000000' >/dev/null 2>&1
wait_for 'vstlb KVM host initramfs' 150 "$OFF" || { echo "!! did not reach the initramfs"; exit 5; }
sleep 2

echo "== [4/5] run: $ITERS iterations"
"$BOARDCTL" send "$BOARD" "/test/run-vstlb.sh $TAG $ITERS $CPU0 $CPU1" >/dev/null 2>&1
wait_for "VSTLB-RUN-DONE tag=$TAG" 1200 "$OFF" || echo "!! the test did not finish"

echo "== [5/5] save evidence"
OUT=$RES/$TAG.log
tail -c +"$OFF" "$LOG" | tr -d '\r' | sed -n "/VSTLB-RUN-START tag=$TAG/,/VSTLB-RUN-DONE tag=$TAG/p" > "$OUT"
grep -E "VSTLB-(RUN-START|PROV|ITER|SUMMARY|RUN-DONE)" "$OUT" | tee "$RES/$TAG.summary.txt"
echo "saved: $OUT"
