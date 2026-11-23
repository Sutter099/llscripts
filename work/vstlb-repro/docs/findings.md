# Measurements

Guest side is identical everywhere: kernel v7.4-rc1, same two binaries, same
guest initramfs.

## Reproduction

| Platform | Host kernel | Iters | BUG | OK | err |
|---|---|---|---|---|---|
| K3 / X100 (harness bugs) | v7.4-rc1 | 12 | 0 | 0 | 12 |
| K3 / X100 | v7.4-rc1 | 19 | **15** | 4 | 0 |
| K3 / X100, patched | v7.4-rc1 + fix | 6 | **0** | 6 | 0 |
| K3 / X100, this layout | v7.4-rc1 | 6 | **5** | 1 | 0 |
| v100, userspace only | Ubuntu 7.0.0-30, untouched | 36 | **31** | 5 | 0 |
| v100, repo scripts | same | 6 | 5 | 1 | 0 |

~80-86% hit rate unpatched, 0/6 with the candidate fix. Different host kernel
and different silicon hit the same entry, so this is a generic RISC-V KVM
issue, not a board quirk.

## U-mode vs S-mode

Control run: guest spins inside one entry, host rewrites the PTE from another
thread — 0 exits, 0 fences — guest still reads the new value. The same timing
in U-mode hits the stale value on the first attempt.

So S-mode accesses in VS-mode do not reuse VS-stage entries on this hardware;
U-mode accesses do. A U-mode payload needs its own page (PTE.U=1 pages cannot
be fetched by S-mode) and `sstatus.SUM` set before the first access to a U page.

## Instrumented kernel

printk in `kvm_riscv_local_tlb_sanitize()` and every local hfence exit:

```
VSTLB flush=1 vcpu1 last_exit=-1 cpu=1   <- vcpu1 first entry, before phase1
VSTLB flush=2 vcpu0 last_exit=-1 cpu=1   <- vcpu0 first entry, before the read
VSTLB flush=3 vcpu0 last_exit=1  cpu=0   <- after migration, on hart0
```

Nothing sanitises the original hart between phase1 and phase3: the stale entry
is real. Instrumented printk interleaves with the payload output, so restore a
clean kernel before taking numbers.

## Guest musts

1. Pin vCPU0, then `execv` yourself. `mm_cpumask` is only added to, never
   cleared; touching vCPU1 at startup makes COW send a remote `sfence.vma` and
   hides the bug — indistinguishable from "no bug".
2. Never exit as PID 1: `return 0` triggers `Attempted to kill init`, the
   `RESULT:` line is lost, the harness only sees rc=2.
3. The initramfs needs a **shell-based init** (busybox mounts the pseudo
   filesystems, then `exec`s the payload). Booting the static payload directly
   as `/init` — even with the same mounts done in C, the same `execv` re-exec
   and a 2s boot delay — gave **0/6** where the busybox layout gave 5/6. The
   cause is not isolated; the layout was reverted rather than debugged further.

## Host musts

- vCPU threads are `CPU 0/KVM` / `CPU 1/KVM`; scan `/proc/<pid>/task/*/comm`.
  QMP `query-cpus-fast` `thread-id` is the alternative.
- Verify with `sched_getaffinity()` that vCPU0 moved and vCPU1 did not.
- Verdict is an exact match on the whole `RESULT:` line.

## Borrowed host: what is touched

Only runtime state and one package; no kernel image, no bootloader, no boot
arguments.

| Item | Persistence |
|---|---|
| `kvm` module (`modprobe kvm`) | runtime, gone after reboot |
| `/dev/kvm` mode (`chmod 666`) | runtime, reset by udev |
| `qemu-system-riscv` package | the only install, `apt remove` undoes it |
| files in the working directory | kit + `results/<tag>/iter-*.log` |

On Ubuntu 26.04 the riscv64 target is **not** in `qemu-system-misc`; the package
is `qemu-system-riscv`.

## Pitfalls

| Pitfall | Symptom |
|---|---|
| no `wdt stop` in U-Boot (board path) | 60s reset, looks like a tftp failure |
| `/incbin(("..."))` in the FIT source | mkimage syntax error |
| changed FIT load addresses | `bootm 0x140000000` fails; kernel `0x1_02200000`, fdt `0x1_20000000`, ramdisk `0x1_30000000` |
| library closure not copied into a board initramfs | binary dies with `No such file or directory` (missing interpreter) |
| new initrd, old FIT | the initrd is embedded in the .itb; rebuild the FIT |
| rc=2+ mixed into the hit rate | infrastructure errors counted as "no bug" |

## kselftest variant (did not work)

- S-mode, two vCPUs: 6/6 PASS; the control run shows it cannot hit the entry.
- U-mode, one vCPU: hits the stale value, but the guest issues no fence —
  keeping the entry is architecturally allowed, so it is not a bug and cannot
  be a regression test.
- U-mode, two vCPUs, migration by signal kick: plumbing works, but kicking the
  vCPU out makes the host run on the original hart and no stale entry survives.

A kselftest-shaped test needs the guest to issue its own local `sfence.vma`
after the migration (U→S return path), or a migration method that does not
pollute the source hart. The out-of-tree harness remains the only reliable path.
