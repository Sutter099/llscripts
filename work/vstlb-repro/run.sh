#!/usr/bin/env bash
# run.sh - run the reproducer N times on this host. Userspace only: QEMU/KVM
# is started as a normal process and the guest kernel is passed with -kernel.
#
#   ./run.sh [tag] [iters] [cpu0] [cpu1]
#
# Needs: riscv64 host with KVM (/dev/kvm), qemu-system-riscv64, a guest kernel
# Image. Only userspace is touched - no kernel rebuild, no boot config.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${1:-run}
ITERS=${2:-8}
CPU0=${3:-0}
CPU1=${4:-1}
DIST=${DIST:-$HERE/dist}
RES=${RES:-$HERE/results}
QEMU=${QEMU:-qemu-system-riscv64}
BIN=$DIST/bin/vstlb_host

# guest kernel: $KERNEL, dist/Image, or this host's own kernel image
KERNEL=${KERNEL:-}
if [ -z "$KERNEL" ]; then
	for c in "$DIST/Image" "/boot/vmlinuz-$(uname -r)"; do
		[ -f "$c" ] && { KERNEL=$c; break; }
	done
fi

die() { echo "!! $*"; exit 2; }

[ -x "$BIN" ]                 || die "missing $BIN (run ./build.sh)"
[ -f "$DIST/guest.cpio.gz" ]  || die "missing dist/guest.cpio.gz (run ./build.sh)"
[ -n "$KERNEL" ] && [ -f "$KERNEL" ] || die "no guest kernel: set KERNEL=/path/to/Image"
[ -w /dev/kvm ]               || die "/dev/kvm not writable (sudo modprobe kvm; sudo chmod 666 /dev/kvm)"
command -v "$QEMU" >/dev/null || die "$QEMU not found (apt install qemu-system-riscv)"
"$QEMU" -accel help 2>&1 | grep -qx kvm || die "$QEMU has no kvm accelerator"

LOG=$RES/$TAG
rm -rf "$LOG"; mkdir -p "$LOG"

echo "RUN tag=$TAG kernel=$(uname -r) qemu=$("$QEMU" --version | head -1)"
echo "RUN guest-kernel=$KERNEL iters=$ITERS cpu0=$CPU0 cpu1=$CPU1"

bug=0; ok=0; err=0; i=1
while [ "$i" -le "$ITERS" ]; do
	"$BIN" --cpu0 "$CPU0" --cpu1 "$CPU1" \
		--kernel "$KERNEL" --initrd "$DIST/guest.cpio.gz" > "$LOG/iter-$i.log" 2>&1
	case $? in
	0) bug=$((bug + 1)); v=BUG_REPRODUCED ;;
	1) ok=$((ok + 1));   v=OK ;;
	*) err=$((err + 1)); v=ERROR ;;
	esac
	echo "ITER $i $v"
	grep -E "PHASE1_READ|PHASE2_READBACK|PHASE3_READ|RESULT:" "$LOG/iter-$i.log" | sed 's/^/    /'
	i=$((i + 1))
done

echo "SUMMARY tag=$TAG total=$ITERS bug=$bug ok=$ok err=$err"
echo "logs: $LOG"
