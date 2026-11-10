# Measurements

v7.4-rc1, `defconfig` + `CONFIG_KVM=y`; SpacemiT K3 / X100, real KVM.

## Reproduction

| Group | Iters | BUG | OK | err |
|---|---|---|---|---|
| base r1–r4 (harness bugs) | 12 | 0 | 0 | 12 |
| base r5 | 3 | 1 | 2 | 0 |
| base r6 | 8 | 7 | 1 | 0 |
| base r7 | 8 | 7 | 1 | 0 |
| base, valid iters | 19 | **15** | 4 | — |
| patched | 6 | **0** | 6 | 0 |

~80% hit rate unpatched, 0/6 patched.

## U-mode vs S-mode

Control run (`vsstage_tlb_ctrl_test`): guest spins inside one entry, host
rewrites the PTE from another thread — 0 exits, 0 fences — guest still reads
the new value. Same timing in U-mode (`vsstage_tlb_user_test`, one vCPU) hits
the stale value on the first attempt.

So S-mode accesses in VS-mode do not reuse VS-stage entries on this hardware;
U-mode accesses do. The kselftest 6/6 PASS was structural, not a timing issue.

For a U-mode payload: code needs its own page (PTE.U=1 pages cannot be fetched
by S-mode) via `section(".text.ucode"), aligned(4096)`; `sstatus.SUM` must be
set before the first access to a U page.

## Instrumented kernel

printk in `kvm_riscv_local_tlb_sanitize()` and every local hfence exit:

```
VSTLB flush=1 vcpu1 last_exit=-1 cpu=1   <- vcpu1 first entry, before phase1
VSTLB flush=2 vcpu0 last_exit=-1 cpu=1   <- vcpu0 first entry, before the read
VSTLB flush=3 vcpu0 last_exit=1  cpu=0   <- after migration, on hart0
```

Nothing sanitises hart1 between phase1 and phase3: the stale entry is real.
Instrumented printk interleaves with the payload's output — restore the clean
kernel before taking numbers.

## Guest musts

1. Pin vCPU0, then `execv` yourself. `mm_cpumask` is only added to, never
   cleared; touching vCPU1 at startup makes COW send a remote `sfence.vma`
   and hides the bug — indistinguishable from "no bug".
2. Never exit as PID 1: `return 0` triggers `Attempted to kill init`, the
   `RESULT:` line is lost, the harness only sees rc=2.

## Host musts

- vCPU threads are `CPU 0/KVM` / `CPU 1/KVM`; scan `/proc/<pid>/task/*/comm`.
  QMP `query-cpus-fast` `thread-id` is the alternative.
- Verify with `sched_getaffinity()` that vCPU0 moved and vCPU1 did not.
- Verdict is an exact match on the whole `RESULT:` line.

## Pitfalls

| Pitfall | Symptom |
|---|---|
| no `wdt stop` in U-Boot | 60s reset, looks like tftp failure |
| `/incbin(("..."))` in the FIT source | mkimage syntax error |
| changed FIT load addresses | `bootm 0x140000000` fails; kernel `0x1_02200000`, fdt `0x1_20000000`, ramdisk `0x1_30000000` |
| no riscv64 binfmt | container exec ENOENT, looks like a broken image |
| full initramfs rebuild for one file | slow; use `repack-initramfs.sh` |
| new initrd, old FIT | initrd is embedded in the .itb; re-run `pack-fit.sh` |

## End-to-end check

Built from this repo on monica (Arch x86_64, 20 cores):

```
ffffffff80c41858 T _etext              <- same as the hand-built base kernel
libs copied: 45, unresolved: none
container mkimage -> dist/Image-vstlb.itb (59M)
```

On the board, 8 iterations: `VSTLB-SUMMARY tag=mnc-r1 total=8 bug=6 ok=2 err=0`
with `VSTLB-PROV ffffffff80c41858`. Repo → build host → .itb → board →
`BUG_REPRODUCED`.

## kselftest variant (did not work)

- S-mode, two vCPUs: 6/6 PASS; the control run shows it cannot hit the entry.
- U-mode, one vCPU: hits the stale value, but the guest issues no fence —
  keeping the entry is architecturally allowed, so it is not a bug and cannot
  be a regression test.
- U-mode, two vCPUs, migration by signal kick: plumbing works, but kicking the
  vCPU out makes the host run on hart1 and no stale entry survives.

A kselftest-shaped test needs the guest to issue its own local `sfence.vma`
after the migration (U→S return path), or a migration method that does not
pollute hart1. The out-of-tree harness remains the only reliable path.
