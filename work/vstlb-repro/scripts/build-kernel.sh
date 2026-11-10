#!/usr/bin/env bash
# build-kernel.sh - cross-build a riscv64 kernel Image (CONFIG_KVM=y) + K3 DTB
#
# Sources are not in git: the first run fetches a tarball into build/,
# unpacks to build/linux-<KVER>, builds incrementally; artefacts land in dist/ (gitignored).
#
# usage:
#   ./scripts/build-kernel.sh                    # clean tree
#   PATCHDIR=patches ./scripts/build-kernel.sh   # apply patches/*.patch (A/B control)
#
# environment:
#   KVER     kernel version, default 7.4-rc1
#   CROSS    cross toolchain prefix, default riscv64-linux-gnu-
#   JOBS     parallelism, default nproc
#   HW       DTB name without .dtb, default k3-pico-itx
#   PATCHDIR directory whose *.patch are applied in name order
#   RECONFIG=1 force a fresh defconfig
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
KVER=${KVER:-7.4-rc1}
CROSS=${CROSS:-riscv64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}
HW=${HW:-k3-pico-itx}
BUILD=${BUILD:-$HERE/build}
DIST=${DIST:-$HERE/dist}
PATCHDIR=${PATCHDIR:-}

SRCDIR=$BUILD/linux-$KVER
mkdir -p "$BUILD" "$DIST"

say() { printf '\n== %s ==\n' "$*"; }

say "kernel $KVER -> $DIST/Image (CONFIG_KVM=y)"

if [ ! -d "$SRCDIR" ]; then
	MAJOR=${KVER%%.*}
	URL=https://cdn.kernel.org/pub/linux/kernel/v$MAJOR.x/linux-$KVER.tar.xz
	TARBALL=$BUILD/linux-$KVER.tar.xz
	if [ ! -f "$TARBALL" ]; then
		say "download $URL"
		curl -fL --retry 3 --progress-bar -o "$TARBALL.part" "$URL"
		mv "$TARBALL.part" "$TARBALL"
	fi
	say "extract $TARBALL"
	tar -C "$BUILD" -xf "$TARBALL"
fi

if [ -n "$PATCHDIR" ]; then
	shopt -s nullglob
	for p in "$PATCHDIR"/*.patch; do
		say "apply $(basename "$p")"
		( cd "$SRCDIR" && patch -p1 --forward --no-backup-if-mismatch < "$p" ) || {
			echo "!! patch failed: $p (already applied?)"; exit 1; }
	done
	shopt -u nullglob
fi

cd "$SRCDIR"
if [ ! -f .config ] || [ "${RECONFIG:-0}" = 1 ]; then
	say "defconfig + CONFIG_KVM=y"
	make ARCH=riscv CROSS_COMPILE="$CROSS" defconfig >/dev/null
	./scripts/config --enable KVM
	make ARCH=riscv CROSS_COMPILE="$CROSS" olddefconfig >/dev/null
fi
grep -q '^CONFIG_KVM=y$' .config || { echo "!! CONFIG_KVM != y in .config"; exit 1; }

say "build Image + dtbs (-j$JOBS)"
make -j"$JOBS" ARCH=riscv CROSS_COMPILE="$CROSS" Image dtbs

cp -f arch/riscv/boot/Image "$DIST/Image"
DTB=$(find arch/riscv/boot/dts -name "$HW.dtb" | head -1)
[ -n "$DTB" ] || { echo "!! cannot find $HW.dtb (wrong HW?)"; exit 1; }
cp -f "$DTB" "$DIST/$HW.dtb"

# provenance: base and patched kernels differ in _etext; the board prints it as VSTLB-PROV
"${CROSS}nm" -n vmlinux | grep ' _etext' | tee "$DIST/Image.prov"

say "done"
ls -lh "$DIST/Image" "$DIST/$HW.dtb"
