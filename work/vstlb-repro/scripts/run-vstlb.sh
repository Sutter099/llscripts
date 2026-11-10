#!/bin/busybox sh
# Run the stale VS-stage TLB reproducer N times on this KVM host.
# usage: run-vstlb.sh <tag> [iters] [vCPU0_host_cpu] [vCPU1_host_cpu]
TAG=${1:-unknown}
N=${2:-3}
CPU0=${3:-0}
CPU1=${4:-1}
BIN=/opt/vstlb/vstlb_host
LOG=/tmp/vstlb-$TAG
rm -rf "$LOG"; mkdir -p "$LOG"

echo "VSTLB-RUN-START tag=$TAG kernel=$(uname -r) iters=$N cpu0=$CPU0 cpu1=$CPU1"
echo "VSTLB-PROV $(grep ' _etext' /proc/kallsyms)"
echo "VSTLB-PROV $(cat /proc/cmdline)"
[ -c /dev/kvm ] || mknod /dev/kvm c 10 232
chmod 666 /dev/kvm

rep=0; ok=0; err=0; i=1
while [ "$i" -le "$N" ]; do
	"$BIN" --cpu0 "$CPU0" --cpu1 "$CPU1" > "$LOG/iter-$i.log" 2>&1
	rc=$?
	case "$rc" in
	0) rep=$((rep + 1)); v=BUG_REPRODUCED ;;
	1) ok=$((ok + 1)); v=OK ;;
	*) err=$((err + 1)); v=ERROR ;;
	esac
	echo "VSTLB-ITER $i rc=$rc $v"
	grep -E "\[host\] (vCPU|VERDICT)|RESULT:|PHASE[123]_(READ|READBACK)|GUEST_ON_CPU|GUEST_INIT|ASID" "$LOG/iter-$i.log" | sed 's/^/    /'
	i=$((i + 1))
done

echo "VSTLB-SUMMARY tag=$TAG total=$N bug=$rep ok=$ok err=$err"
echo "VSTLB-RUN-DONE tag=$TAG"
