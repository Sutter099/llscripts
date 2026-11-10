#!/usr/bin/env bash
# build-all.sh - one shot: kernel + sysroot + two ELFs + two initramfs + FIT
#
#   ./scripts/build-all.sh                 # unpatched kernel
#   PATCHDIR=patches ./scripts/build-all.sh
#
# To build a single stage, call that script on its own (all of them work standalone).
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
TAG=${TAG:-vstlb}
export DIST=${DIST:-$HERE/dist}
export BUILD=${BUILD:-$HERE/build}

say() { printf '\n########## %s ##########\n' "$*"; }

say "1/5 kernel"
"$HERE/scripts/build-kernel.sh"

say "2/5 riscv64 sysroot (qemu + busybox)"
"$HERE/scripts/build-sysroot.sh"

say "3/5 userspace programs"
"$HERE/scripts/build-progs.sh"

say "4/5 initramfs"
"$HERE/scripts/build-initramfs.sh"

say "5/5 FIT"
TAG="$TAG" "$HERE/scripts/pack-fit.sh" -t "$TAG"

say "artifacts in $DIST"
ls -lh "$DIST"/Image "$DIST"/k3-pico-itx.dtb "$DIST"/guest.cpio.gz \
       "$DIST"/initramfs.cpio.gz "$DIST"/Image-"$TAG".itb 2>/dev/null
