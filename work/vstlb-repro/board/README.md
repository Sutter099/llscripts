# board/ — bare K3 / X100 board

Only needed when the target is a naked board instead of a normal riscv64 host.
Everything here boots a FIT over tftp and drives the serial console.

```bash
cd board
./build-kernel.sh        # v7.4-rc1 Image + k3-pico-itx.dtb (CONFIG_KVM=y)
./build-sysroot.sh       # riscv64 qemu + busybox in dist/sysroot (container)
cd .. && ./build.sh      # the two binaries + guest initramfs
cd board
./build-initramfs.sh     # board initramfs: qemu + vstlb_host + guest
./pack-fit.sh -t base-r1 # -> dist/Image-base-r1.itb
./run-on-k3.sh base-r1 8 # power cycle, tftp, bootm, run 8 iterations
```

`run-on-k3.sh` needs `boardctl.sh` (`BOARDCTL=...`), a tftp root (`TFTP=...`,
default `/srv/tftp`) and the board on serial. Results land in
`results/<tag>.log`; a run is only meaningful if `VSTLB-PROV` shows the kernel
`_etext` you expect.

Known failure modes: missing `wdt stop` (60s watchdog reset), a FIT whose load
addresses were edited, and an initramfs without the shared-library closure
(dies with `No such file or directory`).

A/B control: `PATCHDIR=../patches ./build-kernel.sh`, then pack and run with a
second tag. The patch must be in the **host** kernel; the guest kernel is
irrelevant.
