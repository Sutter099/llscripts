# vstlb-repro

Stale **VS-stage TLB entry** in RISC-V KVM. After a vCPU is migrated to another
hart, the entry left on the old hart is not invalidated; another vCPU of the
same VM hits it there and reads a stale translation.

Scripts and sources only — the kernel image, initramfs, sysroot and FIT are
generated on the build host and never committed.

## Quick start

```bash
./scripts/build-all.sh             # kernel + sysroot + 2 ELFs + 2 initramfs + .itb
./scripts/run-on-k3.sh base-r1 8   # boot board, 8 iterations, log in results/
```

| Artefact (`dist/`) | Purpose |
|---|---|
| `Image` | riscv64 kernel, `CONFIG_KVM=y`, host and guest |
| `k3-pico-itx.dtb` | from `make dtbs` |
| `guest.cpio.gz` | guest initramfs |
| `initramfs.cpio.gz` | board initramfs (contains qemu) |
| `Image-<tag>.itb` | FIT for `tftpboot` + `bootm` |

## Dependencies

| Need | For | Missing symptom |
|---|---|---|
| `riscv64-linux-gnu-gcc` | kernel, both ELFs | — |
| `mkimage` (u-boot-tools) | FIT | `mkimage: not found` |
| `cpio` `gzip` `curl` `python3` | initramfs, download, lib closure | — |
| podman/docker + riscv64 binfmt | riscv64 qemu + busybox | container exec: `no such file or directory` |
| K3/X100 board, serial, tftp | real hardware | TCG cannot reproduce this |

```bash
sudo pacman -S riscv64-linux-gnu-gcc u-boot-tools cpio python podman qemu-user-static-binfmt
# Debian: gcc-riscv64-linux-gnu u-boot-tools cpio python3 podman qemu-user-static binfmt-support
```

## Why a full guest Linux

Five conditions must hold together; miss one and the reader always sees the
new value:

1. one VM, two vCPUs, same VMID
2. same non-zero ASID on both vCPUs
3. the entry is created by a **U-mode** access
4. the update flushes **locally** only (guest `sfence.vma`, no broadcast)
5. the vCPU is migrated between creation and update

kselftest / kvm-unit-tests payloads run in VS-mode S with no U-mode and no
real ASID allocator; TCG has no hardware TLB residue. A real guest Linux
supplies `mm_cpumask`, ASIDs and the COW-triggered local `sfence.vma`.

## Layout

```
scripts/build-kernel.sh      Image + DTB        scripts/pack-fit.sh       .itb
scripts/build-sysroot.sh     riscv64 qemu/busybox  scripts/build-all.sh    all stages
scripts/build-progs.sh       the two ELFs       scripts/run-on-k3.sh      board run
scripts/build-initramfs.sh   both initramfs     scripts/run-vstlb.sh      on-board loop
scripts/repack-initramfs.sh  replace one file   scripts/mkclosure.py      lib closure
src/vstlb_host.c             host controller    src/vstlb_guest.c         guest victim
patches/                     A/B patch          docs/findings.md          measurements
```

## Reading the result

```
VSTLB-PROV ffffffff80c41858 T _etext     <- which kernel actually runs
VSTLB-SUMMARY tag=base-r1 total=8 bug=7 ok=1 err=0
```

| rc | Meaning |
|---|---|
| 0 | stale value read — stale VS-stage entry hit |
| 1 | new value read |
| 2+ | infrastructure error, iteration does not count |

Probabilistic: one PASS/FAIL means nothing, run at least 8.

## A/B control

```bash
PATCHDIR=patches TAG=fix-r1 ./scripts/build-all.sh
./scripts/run-on-k3.sh base-r1 8
./scripts/run-on-k3.sh fix-r1  8
```

Different `_etext` per kernel — that is what `VSTLB-PROV` proves.
