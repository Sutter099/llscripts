#!/usr/bin/env bash
# build-initramfs.sh - build both initramfs images (generated here, no cpio in git)
#
#   dist/guest.cpio.gz    for the guest Linux: busybox + vstlb_guest + init
#   dist/initramfs.cpio.gz runs on the board: busybox + qemu + vstlb_host + guest kernel + guest cpio
#
# usage:
#   ./scripts/build-initramfs.sh                       # take everything from dist/
#   ./scripts/build-initramfs.sh -k dist/Image -s dist/sysroot -o dist
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DIST=${DIST:-$HERE/dist}
KERNEL=${KERNEL:-$DIST/Image}
SYS=${SYSROOT:-$DIST/sysroot}
OUT=${OUT:-$DIST}
BIN=${BIN:-$DIST/bin}

say() { printf '\n== %s ==\n' "$*"; }
die() { echo "!! $*"; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	-k) KERNEL=$2; shift 2 ;;
	-s) SYS=$2;    shift 2 ;;
	-o) OUT=$2;    shift 2 ;;
	*) die "unknown argument $1" ;;
	esac
done

[ -f "$KERNEL" ]              || die "missing kernel Image: $KERNEL (run build-kernel.sh first)"
[ -x "$SYS/usr/bin/qemu-system-riscv64" ] || die "missing $SYS/usr/bin/qemu-system-riscv64 (run build-sysroot.sh first)"
[ -e "$SYS/bin/busybox" ]     || die "missing $SYS/bin/busybox"
[ -x "$BIN/vstlb_host" ]      || die "missing $BIN/vstlb_host (run build-progs.sh first)"
[ -x "$BIN/vstlb_guest" ]     || die "missing $BIN/vstlb_guest"

mkdir -p "$OUT"
GR=$OUT/.guest-root
HR=$OUT/.host-root
rm -rf "$GR" "$HR"

# ---------- guest ----------
say "guest initramfs"
mkdir -p "$GR"/{bin,proc,sys,dev,tmp}
cp "$SYS/bin/busybox" "$GR/bin/busybox"
cp "$BIN/vstlb_guest" "$GR/vstlb_guest"
cp "$HERE/scripts/guest-init" "$GR/init"
chmod 755 "$GR/bin/busybox" "$GR/vstlb_guest" "$GR/init"
( cd "$GR" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$OUT/guest.cpio.gz" )
ls -lh "$OUT/guest.cpio.gz"

# ---------- host (board side) ----------
say "host initramfs"
mkdir -p "$HR"/{bin,proc,sys,dev,dev/pts,tmp,opt/vstlb,test,usr/bin}
cp "$SYS/bin/busybox" "$HR/bin/busybox"
cp "$KERNEL"          "$HR/opt/vstlb/Image"
cp "$OUT/guest.cpio.gz" "$HR/opt/vstlb/guest.cpio.gz"
cp "$BIN/vstlb_host"  "$HR/opt/vstlb/vstlb_host"
cp "$HERE/scripts/run-vstlb.sh" "$HR/test/run-vstlb.sh"
cp "$HERE/scripts/host-init"    "$HR/init"
cp -a "$SYS/usr/bin/qemu-system-riscv64" "$HR/usr/bin/"
chmod 755 "$HR/bin/busybox" "$HR/opt/vstlb/vstlb_host" "$HR/test/run-vstlb.sh" "$HR/init"

# vstlb_host is dynamically linked: pull in its library closure; the static guest does not need it
say "library closure (vstlb_host + qemu)"
SYS="$SYS" ROOT="$HR" python3 "$HERE/scripts/mkclosure.py" \
	/opt/vstlb/vstlb_host /usr/bin/qemu-system-riscv64

( cd "$HR" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1 > "$OUT/initramfs.cpio.gz" )
rm -rf "$GR" "$HR"
ls -lh "$OUT/initramfs.cpio.gz"
