#!/usr/bin/env bash
# run-on-host.sh - run the reproducer on the *current* riscv64 host.
#
# Unlike run-on-k3.sh this does not boot anything: it only starts QEMU/KVM as a
# normal user process, so a borrowed host keeps its kernel and its boot config.
#
# usage: ./scripts/run-on-host.sh <tag> [iters] [cpu0] [cpu1]
#
# expects in $DIST (default: ./): vstlb_host, guest.cpio.gz, Image
# writes logs to $RES/vstlb-<tag>/iter-<n>.log
set -uo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?usage: run-on-host.sh <tag> [iters] [cpu0] [cpu1]}
ITERS=${2:-8}
CPU0=${3:-0}
CPU1=${4:-1}
DIST=${DIST:-$PWD}
RES=${RES:-$DIST}
QEMU=${QEMU:-qemu-system-riscv64}

die() { echo "!! $*"; exit 2; }

[ -x "$DIST/vstlb_host" ]      || die "missing $DIST/vstlb_host"
[ -f "$DIST/guest.cpio.gz" ]   || die "missing $DIST/guest.cpio.gz"
[ -f "$DIST/Image" ]           || die "missing $DIST/Image (guest kernel)"
[ -w /dev/kvm ]                || die "/dev/kvm not writable (sudo chmod 666 /dev/kvm)"
command -v "$QEMU" >/dev/null  || die "$QEMU not found (apt install qemu-system-riscv)"
"$QEMU" -accel help 2>&1 | grep -qx kvm || die "$QEMU has no kvm accelerator"

LOG=$RES/vstlb-$TAG
rm -rf "$LOG"; mkdir -p "$LOG"

echo "HOST-RUN-START tag=$TAG kernel=$(uname -r) qemu=$("$QEMU" --version | head -1) iters=$ITERS cpu0=$CPU0 cpu1=$CPU1"

bug=0; ok=0; err=0; i=1
while [ "$i" -le "$ITERS" ]; do
	( cd "$DIST" && ./vstlb_host --cpu0 "$CPU0" --cpu1 "$CPU1" \
		--kernel ./Image --initrd ./guest.cpio.gz ) > "$LOG/iter-$i.log" 2>&1
	rc=$?
	case "$rc" in
	0) bug=$((bug + 1)); v=BUG_REPRODUCED ;;
	1) ok=$((ok + 1));   v=OK ;;
	*) err=$((err + 1)); v=ERROR ;;
	esac
	echo "HOST-ITER $i rc=$rc $v"
	grep -E "PHASE1_READ|PHASE2_READBACK|PHASE3_READ|RESULT:" "$LOG/iter-$i.log" | sed 's/^/    /'
	i=$((i + 1))
done

echo "HOST-SUMMARY tag=$TAG total=$ITERS bug=$bug ok=$ok err=$err"
ls "$LOG" | wc -l | sed 's/^/logs: /'
