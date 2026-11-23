#!/usr/bin/env bash
# build.sh - cross-build the two riscv64 binaries and the guest initramfs.
#
#   dist/bin/vstlb_host    host controller (dynamic; runs on the KVM host)
#   dist/bin/vstlb_guest   guest victim (static)
#   dist/guest.cpio.gz     guest initramfs: busybox sh + the static payload
#
# The guest initramfs needs one riscv64 static busybox. Point BUSYBOX at it, or
# fetch it once:
#   apt download busybox-static && dpkg -x busybox-static_*_riscv64.deb /tmp/bb
#   BUSYBOX=/tmp/bb/bin/busybox ./build.sh
# (a busybox taken from a riscv64 sysroot works too).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CROSS=${CROSS:-riscv64-linux-gnu-}
DIST=${DIST:-$HERE/dist}
BUSYBOX=${BUSYBOX:-/bin/busybox}
mkdir -p "$DIST/bin"

say() { printf '== %s ==\n' "$*"; }
die() { echo "!! $*"; exit 1; }

say "vstlb_host (dynamic)"
"${CROSS}gcc" -O2 -g -Wall -Wextra -pthread -o "$DIST/bin/vstlb_host" "$HERE/src/vstlb_host.c"

say "vstlb_guest (static)"
"${CROSS}gcc" -O2 -g -Wall -Wextra -static -o "$DIST/bin/vstlb_guest" "$HERE/src/vstlb_guest.c"

say "guest initramfs"
file -b "$BUSYBOX" | grep -q "UCB RISC-V" || \
	die "$BUSYBOX is not a riscv64 binary - set BUSYBOX=/path/to/riscv64-busybox"

R=$(mktemp -d)
mkdir -p "$R"/{bin,proc,sys,dev,tmp,usr/bin,usr/sbin,sbin}
cp "$BUSYBOX" "$R/bin/busybox"
cp "$DIST/bin/vstlb_guest" "$R/vstlb_guest"
cp "$HERE/guest-init" "$R/init"
chmod 755 "$R/bin/busybox" "$R/vstlb_guest" "$R/init"
( cd "$R" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$DIST/guest.cpio.gz" )
rm -rf "$R"

file -b "$DIST/bin/vstlb_host" | sed 's/^/host:   /'
file -b "$DIST/bin/vstlb_guest" | sed 's/^/guest:  /'
ls -lh "$DIST/guest.cpio.gz"
