#!/bin/bash
# Overlay a single file into an existing initramfs cpio.gz (no full rebuild).
# usage: repack_initramfs.sh <initramfs.cpio.gz> <host-file> <path-in-image>
set -euo pipefail

IMG="$1"
SRC="$2"
DST="$3"
WORK=$(mktemp -d /tmp/repack-vstlb.XXXXXX)

gunzip -c "$IMG" > "$WORK/base.cpio"
mkdir -p "$WORK/stage/$(dirname "$DST")"
cp "$SRC" "$WORK/stage/$DST"
chmod 755 "$WORK/stage/$DST"

(cd "$WORK/stage" && find . -print0 | cpio --null -o -H newc 2>/dev/null) > "$WORK/inc.cpio"
cat "$WORK/base.cpio" "$WORK/inc.cpio" | gzip -1 > "$WORK/out.cpio.gz"
cp "$WORK/out.cpio.gz" "$IMG"

echo "repacked: $IMG  ($(stat -c%s "$IMG") bytes)  $DST <- $SRC"
python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$WORK"
