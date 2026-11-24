# vstlb-repro

Stale **VS-stage TLB entry** in RISC-V KVM.

A vCPU is migrated to another hart; the VS-stage entry it created on the old
hart is not invalidated; another vCPU of the same VM hits that entry there and
reads a **stale translation**.

## Five conditions

All must hold, otherwise the reader always sees the new value:

1. one VM, two vCPUs, same VMID
2. both vCPUs share the same non-zero ASID
3. the entry is created by a **U-mode** access (S-mode does not reuse it here)
4. the mapping update flushes **locally** only (guest `sfence.vma`)
5. the vCPU is migrated between creation and update

## Run it

```bash
CROSS=riscv64-linux-gnu- BUSYBOX=/path/to/riscv64-busybox ./build.sh
KERNEL=/path/to/Image ./run.sh tag 8 0 1   # 8 iterations, logs in results/
```

On the KVM host you need `qemu-system-riscv64` with the kvm accelerator and a
writable `/dev/kvm`. Nothing else: the guest kernel is passed with `-kernel` and
the guest payload is a static ELF, so no sysroot, no library closure and **no
kernel rebuild**. `build.sh` only needs one riscv64 static busybox to build the
guest initramfs (`apt download busybox-static && dpkg -x ...`).

`KERNEL` can be omitted if `dist/Image` exists; otherwise `run.sh` falls back to
`/boot/vmlinuz-$(uname -r)`.

## Results

| Platform | Host kernel | Iters | Hits |
|---|---|---|---|
| SpacemiT K3 / X100 | v7.4-rc1, unpatched | 19 | 15 |
| SpacemiT K3 / X100 | v7.4-rc1 + fix | 6 | 0 |
| SpacemiT v100 | Ubuntu 7.0.0-30, untouched | 42 | 36 (86%) |

Different silicon and a different host kernel give the same result, so this is
a generic RISC-V KVM issue, not a board quirk. Measurements and pitfalls:
[docs/findings.md](docs/findings.md).

## Layout

```
build.sh     cross-build both binaries + guest initramfs
run.sh       run N iterations on this host (userspace only)
src/         vstlb_host.c (controller, QMP, affinity) + vstlb_guest.c (victim)
docs/        measurements, U-mode vs S-mode finding, pitfalls
patches/     candidate fix, for the A/B control
board/       K3/X100 only: FIT, tftp, serial, custom host kernel - see board/README.md
```

`board/` is only needed to reproduce on a bare board. On any riscv64 host with
KVM the two commands above are enough.
