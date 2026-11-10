#!/usr/bin/env bash
# pack-fit.sh - kernel Image + DTB + host initramfs -> one FIT (.itb)
#
# usage:
#   ./scripts/pack-fit.sh -t base-r1
#   ./scripts/pack-fit.sh -t fix-r1 -k dist/Image-fix -i dist/initramfs.cpio.gz -o dist
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
command -v mkimage >/dev/null || { echo "!! missing mkimage (pacman -S u-boot-tools)"; exit 1; }
mkdir -p "$OUT"

ITS=$OUT/.$TAG.its
sed -e "s|__KIMG__|$(readlink -f "$KIMG")|" \
    -e "s|__FDT__|$(readlink -f "$FDT")|" \
    -e "s|__INITRD__|$(readlink -f "$INITRD")|" \
    "$HERE/scripts/k3-vstlb.its" > "$ITS"

say "mkimage -> $OUT/Image-$TAG.itb"
mkimage -f "$ITS" "$OUT/Image-$TAG.itb"
rm -f "$ITS"
ls -lh "$OUT/Image-$TAG.itb"

say "provenance (kernel _etext baked into the FIT)"
if [ -f "$DIST/Image.prov" ]; then cat "$DIST/Image.prov"; fi
