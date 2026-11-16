# Borrowed riscv64 host (userspace only)

Use this when the host must stay untouched: no kernel rebuild, no bootloader,
no boot arguments. The reproducer is an ordinary userspace process that starts
QEMU/KVM; the guest kernel is handed to QEMU with `-kernel`.

## Requirements

- riscv64 host with the hypervisor extension and a loadable `kvm` module
- `qemu-system-riscv` (on Ubuntu 26.04 the riscv64 target is **not** in
  `qemu-system-misc`; that package only ships alpha/avr/hppa/loongarch64/m68k/
  microblaze/or1k/rx/sh4/tricore/xtensa)
- `/dev/kvm` writable by the user

```bash
sudo modprobe kvm
sudo chmod 666 /dev/kvm
sudo apt install qemu-system-riscv
```

On the build host:

```bash
./scripts/build-all.sh          # kernel Image, guest initramfs, both ELFs
./scripts/build-host-kit.sh     # -> dist/vstlb-host-kit.tar.gz
```

On the borrowed host, in the directory the owner gave you:

```bash
tar xzf vstlb-host-kit.tar.gz -C ~/dropbox && cd ~/dropbox
./run-on-host.sh <tag> 8 0 1
```

## What is touched

| Item | Persistence |
|---|---|
| `kvm` module | runtime only, gone after reboot |
| `/dev/kvm` mode | runtime only, reset by udev on reboot |
| `qemu-system-riscv` package | the only install; `apt remove` undoes it |
| files under the working directory | kit + `vstlb-<tag>/iter-*.log` |

No kernel image, no FIT, no bootloader, no `/boot` or `/etc` changes.

## Measured

SpacemiT v100, Ubuntu 26.04, kernel `7.0.0-30-generic` (unmodified),
80 harts, QEMU 10.2.1, `-accel kvm`:

| Group | Iters | BUG | OK | err |
|---|---|---|---|---|
| v100-r1 | 12 | 11 | 1 | 0 |
| v100-r2 | 24 | 20 | 4 | 0 |
| total | 36 | **31 (86%)** | 5 | 0 |

Guest kernel (7.4-rc1) and both binaries are identical to the K3 runs; only the
host kernel and the silicon differ. The stale entry is therefore a generic
RISC-V KVM issue, not something specific to the K3/X100 board.
