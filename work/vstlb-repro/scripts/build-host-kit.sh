#!/usr/bin/env bash
# build-host-kit.sh - stage everything the reproducer needs on a borrowed
# riscv64 host: host controller, guest program, guest initramfs, guest kernel
# and the runner. Nothing on the target host is modified; the kit is a tarball.
#
# usage: ./scripts/build-host-kit.sh [outdir]
#
# needs dist/bin/* and dist/guest.cpio.gz from build-progs.sh / build-initramfs.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DIST=${DIST:-$HERE/dist}
OUT=${1:-$HERE/dist}
KIT=$OUT/vstlb-host-kit

say() { printf '\n== %s ==\n' "$*"; }

[ -x "$DIST/bin/vstlb_host" ]  || { echo "!! run build-progs.sh first"; exit 1; }
[ -f "$DIST/guest.cpio.gz" ]   || { echo "!! run build-initramfs.sh first"; exit 1; }
[ -f "$DIST/Image" ]           || { echo "!! run build-kernel.sh first"; exit 1; }

rm -rf "$KIT"; mkdir -p "$KIT"
cp "$DIST/bin/vstlb_host" "$KIT/"
cp "$DIST/guest.cpio.gz"  "$KIT/"
cp "$DIST/Image"          "$KIT/"
cp "$HERE/scripts/run-on-host.sh" "$KIT/"

( cd "$KIT" && tar -czf "$OUT/vstlb-host-kit.tar.gz" . )
say "kit: $OUT/vstlb-host-kit.tar.gz"
ls -lh "$OUT/vstlb-host-kit.tar.gz"

cat <<'EOF'

On the target host (riscv64, KVM available):

  tar xzf vstlb-host-kit.tar.gz -C ~/dropbox
  cd ~/dropbox
  ./run-on-host.sh <tag> 8 0 1

Only userspace is touched: modprobe kvm, one device mode on /dev/kvm and a
qemu-system-riscv package. No kernel, no bootloader, no boot arguments.
EOF
