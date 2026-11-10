#!/usr/bin/env bash
# pack-fit.sh - kernel Image + DTB + host initramfs -> one FIT (.itb)
#
# usage:
#   ./scripts/pack-fit.sh -t base-r1
#   ./scripts/pack-fit.sh -t fix-r1 -k dist/Image-fix -o dist
#
# mkimage comes from one of two places:
#   1. the host mkimage (fastest)
#   2. if the host one is broken/missing (e.g. libssl.so.4) -> fall back to mkimage in a debian container
#
# note: the load addresses are what bootm 0x140000000 in K3 U-Boot relies on - do not change.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DIST=${DIST:-$HERE/dist}
TAG=${TAG:-vstlb}
KIMG=${KIMG:-$DIST/Image}
FDT=${FDT:-$DIST/k3-pico-itx.dtb}
INITRD=${INITRD:-$DIST/initramfs.cpio.gz}
OUT=${OUT:-$DIST}
ENGINE=${ENGINE:-}
CTR_IMAGE=${CTR_IMAGE:-docker.io/library/debian:trixie-slim}

say() { printf '\n== %s ==\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	-t) TAG=$2;    shift 2 ;;
	-k) KIMG=$2;   shift 2 ;;
	-d) FDT=$2;    shift 2 ;;
	-i) INITRD=$2; shift 2 ;;
	-o) OUT=$2;    shift 2 ;;
	*) echo "!! unknown argument $1"; exit 2 ;;
	esac
done

for f in "$KIMG" "$FDT" "$INITRD"; do
	[ -f "$f" ] || { echo "!! missing file: $f"; exit 1; }
done
mkdir -p "$OUT"

# stage the three inputs in one directory: the container fallback mounts only this
STAGE=$OUT/.fit
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -f "$KIMG"   "$STAGE/Image"
cp -f "$FDT"    "$STAGE/board.dtb"
cp -f "$INITRD" "$STAGE/initramfs.cpio.gz"

gen_its() {	# $1 = incbin path prefix
	sed -e "s|__KIMG__|$1/Image|" \
	    -e "s|__FDT__|$1/board.dtb|" \
	    -e "s|__INITRD__|$1/initramfs.cpio.gz|" \
	    "$HERE/scripts/k3-vstlb.its"
}

ITB=$OUT/Image-$TAG.itb
DONE=0

if command -v mkimage >/dev/null 2>&1; then
	say "host mkimage -> $ITB"
	gen_its "$STAGE" > "$STAGE/fit.its"
	if mkimage -f "$STAGE/fit.its" "$ITB" 2> "$STAGE/mkimage.err"; then
		DONE=1
	else
		echo "   host mkimage failed: $(head -1 "$STAGE/mkimage.err")"
	fi
fi

if [ "$DONE" = 0 ]; then
	if [ -z "$ENGINE" ]; then
		if command -v podman >/dev/null; then ENGINE=podman
		elif command -v docker >/dev/null; then ENGINE=docker
		else echo "!! no usable mkimage and no podman/docker"; exit 1; fi
	fi
	say "container mkimage ($ENGINE, $CTR_IMAGE) -> $ITB"
	gen_its "/d/.fit" > "$STAGE/fit.its"
	"$ENGINE" run --rm -v "$OUT:/d" "$CTR_IMAGE" /bin/sh -c \
		'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq u-boot-tools >/dev/null 2>&1 && exec mkimage -f /d/.fit/fit.its /d/'"$(basename "$ITB")"
fi

rm -rf "$STAGE"
ls -lh "$ITB"

say "provenance (kernel _etext baked into the FIT)"
[ -f "$DIST/Image.prov" ] && cat "$DIST/Image.prov" || true
