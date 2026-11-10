#!/usr/bin/env bash
# build-progs.sh - cross-build the two riscv64 ELFs
#
#   vstlb_host   dynamically linked, runs in the board initramfs (host controller)
#   vstlb_guest  -static, runs inside the guest Linux (victim process)
#
# Output in dist/bin/, not tracked by git.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DIST=${DIST:-$HERE/dist}
CROSS=${CROSS:-riscv64-linux-gnu-}
mkdir -p "$DIST/bin"

say() { printf '\n== %s ==\n' "$*"; }

say "vstlb_host"
"${CROSS}gcc" -O2 -g -Wall -Wextra -pthread -o "$DIST/bin/vstlb_host" "$HERE/src/vstlb_host.c"

say "vstlb_guest (static)"
"${CROSS}gcc" -O2 -g -Wall -Wextra -static -o "$DIST/bin/vstlb_guest" "$HERE/src/vstlb_guest.c"

file "$DIST/bin/vstlb_host" "$DIST/bin/vstlb_guest"
