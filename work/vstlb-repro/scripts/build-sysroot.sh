#!/usr/bin/env bash
# build-sysroot.sh - prepare the riscv64 userland (qemu-system-riscv64 + busybox for the board)
#
# No binaries in git: a riscv64 container is used to drop qemu/busybox into
# dist/sysroot/, from where build-initramfs.sh copies files and mkclosure.py resolves libs.
#
# usage:
#   ./scripts/build-sysroot.sh                 # pick podman/docker automatically
#   ENGINE=docker ./scripts/build-sysroot.sh
#   SYSROOT=/path ./scripts/build-sysroot.sh   # use an existing riscv64 rootfs (skip container)
#
# requires (Arch): pacman -S qemu-user-static-binfmt   # else riscv64 container exec fails with ENOENT
# requires (Debian/Ubuntu): apt install qemu-user-static binfmt-support
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DIST=${DIST:-$HERE/dist}
SYS=${SYSROOT:-$DIST/sysroot}
IMAGE=${IMAGE:-docker.io/riscv64/debian:trixie-slim}

say() { printf '\n== %s ==\n' "$*"; }

if [ -x "$SYS/usr/bin/qemu-system-riscv64" ] && [ -e "$SYS/bin/busybox" ]; then
	say "sysroot already present: $SYS"
	file "$SYS/usr/bin/qemu-system-riscv64"
	exit 0
fi

if [ -n "${SYSROOT:-}" ]; then
	echo "!! SYSROOT=$SYSROOT lacks usr/bin/qemu-system-riscv64 or bin/busybox"
	exit 1
fi

ENGINE=${ENGINE:-}
if [ -z "$ENGINE" ]; then
	if command -v podman >/dev/null; then ENGINE=podman
	elif command -v docker >/dev/null; then ENGINE=docker
	else echo "!! need podman or docker"; exit 1; fi
fi

mkdir -p "$SYS"
say "pulling qemu-system-misc + busybox-static from $IMAGE (emulated, a few minutes)"

$ENGINE run --rm --arch riscv64 -v "$SYS:/out" "$IMAGE" /bin/sh -c '
set -e
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
	qemu-system-misc busybox-static
for d in usr lib lib64 bin etc; do
	[ -d "/$d" ] && tar -C / -cf - "./$d" | tar -C /out -xf -
done
# the real busybox binary from busybox-static
[ -f /bin/busybox ] && cp -f /bin/busybox /out/bin/busybox || cp -f /usr/bin/busybox /out/bin/busybox
'

say "verify"
file "$SYS/usr/bin/qemu-system-riscv64" | grep -qi 'risc-v\|riscv' || {
	echo "!! qemu-system-riscv64 is not a riscv64 ELF"; exit 1; }
file "$SYS/bin/busybox" | grep -qi 'risc-v\|riscv\|statically linked' || true
du -sh "$SYS"
