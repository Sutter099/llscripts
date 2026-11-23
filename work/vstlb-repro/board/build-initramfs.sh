#!/usr/bin/env bash
# build-initramfs.sh - build the *board* initramfs (host side of the harness).
#
# The guest initramfs is produced by ../build.sh; this wraps it together with
# qemu, the host controller and a copy of the kernel, so a single FIT can be
# tftp'd and bootm'd on a bare board.
#
#   dist/initramfs.cpio.gz  busybox + qemu + vstlb_host + Image + guest.cpio.gz
#
# needs: dist/bin/vstlb_host, dist/guest.cpio.gz (../build.sh), dist/Image,
#        dist/sysroot (build-sysroot.sh)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOTDIR=$(cd "$HERE/.." && pwd)
DIST=${DIST:-$ROOTDIR/dist}
SYS=${SYSROOT:-$DIST/sysroot}
KERNEL=${KERNEL:-$DIST/Image}
OUT=${OUT:-$DIST}

say() { printf '== %s ==\n' "$*"; }
die() { echo "!! $*"; exit 1; }

[ -x "$DIST/bin/vstlb_host" ] || die "missing dist/bin/vstlb_host (run ../build.sh)"
[ -f "$DIST/guest.cpio.gz" ]  || die "missing dist/guest.cpio.gz (run ../build.sh)"
[ -f "$KERNEL" ]              || die "missing kernel Image: $KERNEL"
[ -x "$SYS/usr/bin/qemu-system-riscv64" ] || die "missing $SYS/usr/bin/qemu-system-riscv64 (run build-sysroot.sh)"
[ -e "$SYS/bin/busybox" ]     || die "missing $SYS/bin/busybox"

R=$OUT/.board-root
rm -rf "$R"
mkdir -p "$R"/{bin,proc,sys,dev,dev/pts,tmp,opt/vstlb,test,usr/bin}

cp "$SYS/bin/busybox" "$R/bin/busybox"
cp "$KERNEL"          "$R/opt/vstlb/Image"
cp "$DIST/guest.cpio.gz" "$R/opt/vstlb/guest.cpio.gz"
cp "$DIST/bin/vstlb_host" "$R/opt/vstlb/vstlb_host"
cp "$HERE/run-vstlb.sh"   "$R/test/run-vstlb.sh"
cp "$HERE/host-init"      "$R/init"
cp -a "$SYS/usr/bin/qemu-system-riscv64" "$R/usr/bin/"
chmod 755 "$R/bin/busybox" "$R/opt/vstlb/vstlb_host" "$R/test/run-vstlb.sh" "$R/init"

say "library closure (vstlb_host + qemu)"
SYS="$SYS" ROOT="$R" python3 "$HERE/mkclosure.py" \
	/opt/vstlb/vstlb_host /usr/bin/qemu-system-riscv64

( cd "$R" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1 > "$OUT/initramfs.cpio.gz" )
rm -rf "$R"
ls -lh "$OUT/initramfs.cpio.gz"
