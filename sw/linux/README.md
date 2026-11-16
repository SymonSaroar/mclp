# Linux: PetaLinux 2025.1

Linux for MCLP on the ZC702: a PetaLinux 2025.1 project in the system device tree (SDT) flow,
the `meta-mclp` layer that gives user space access to the PL, and `mclp`, the Linux console. The
sections below build the SD card image from this folder and boot it.

## What is in this folder

| Path | Purpose |
|---|---|
| `.petalinux/metadata` | PetaLinux project metadata (tool version, project type) |
| `.gitignore` | PetaLinux's ignore list: build products stay out of version control |
| `project-spec/configs/config` | Project configuration: hardware description, boot settings, root file system type, user layers |
| `project-spec/configs/rootfs_config` | Root file system package selection |
| `project-spec/hw-description/` | System device tree from `sdtgen` (`system-top.dts`, `pl.dtsi`, `pcw.dtsi`), the bitstream (`*.bit`) and `ps7_init` |
| `project-spec/meta-user/` | PetaLinux's per-project layer: `conf/petalinuxbsp.conf` (thread limits, `mclp` in the image) and an empty `system-user.dtsi` |
| `meta-mclp/conf/layer.conf` | Declares the layer; `MCLP_SW_DIR` points at the repository's `sw/` for the shared sources |
| `meta-mclp/recipes-bsp/device-tree/files/mclp.dtsi` | Device-tree additions: UIO node for the register block, AXI DMA handed to UIO, 4 MB reserved for the capture ring |
| `meta-mclp/recipes-bsp/device-tree/device-tree.bbappend` | Adds `mclp.dtsi` to the generated device tree |
| `meta-mclp/recipes-apps/mclp/mclp.bb` | Builds `mclp` from `sw/common` and `mclp/`, installs it with the boot script and the module option |
| `meta-mclp/recipes-apps/mclp/files/mclp.init` | Boot script (`/etc/init.d/mclp`): loads the UIO driver, runs `mclp init` |
| `meta-mclp/recipes-apps/mclp/files/mclp-uio.conf` | `/etc/modprobe.d/mclp-uio.conf`: makes the UIO driver bind `generic-uio` nodes |
| `mclp/main.c` | `mclp`: argument parsing and register access through UIO |
| `mclp/Makefile` | Builds `mclp` with the compiler in `CC` (the recipe passes the cross compiler) |
| `images/linux/` | Build output, created by `petalinux-build`; not in git |

The console logic itself (commands, register operations, calibration) is in `sw/common` and is shared with
the bare-metal console.

Key files in `images/linux/` after a build:

| File | Use |
|---|---|
| `BOOT.BIN` | First-stage boot loader, bitstream and U-Boot, for the SD card or QSPI (`petalinux-package boot`) |
| `boot.scr` | U-Boot script that loads the kernel, device tree and root file system |
| `image.ub` | FIT image with the kernel and device tree |
| `zImage`, `uImage` | Linux kernel (`zImage` for JTAG) |
| `system.dtb` | Linux device tree, with `mclp.dtsi` merged in |
| `rootfs.ext4` | Root file system, the SD card's second partition |
| `rootfs.cpio.gz.u-boot` | Root file system as an initial RAM disk, for INITRD builds |
| `system.bit` | The PL bitstream |
| `zynq_fsbl.elf`, `u-boot.elf` | Boot loaders for JTAG boot |
| `petalinux-sdimage.wic` | SD card image (`petalinux-package wic`), written to the card in one step |
| `rootfs.manifest` | Every package in the root file system, with versions |

## 1. Host

PetaLinux 2025.1 supports Ubuntu 22.04.2 to 22.04.5, AlmaLinux 8.10, 9.4 and 9.5, and openSUSE Leap 15.4.
On Ubuntu 24.04 (WSL2 included) the image and the recipes here build, but `petalinux-build --sdk` fails:
PetaLinux's `pseudo` loses track of directories that `tar` 1.35 creates, and packaging the SDK's host tools
stops with `uid not found: 1000`. Nothing in this project needs the SDK.

1. `/bin/sh` must be bash: `sudo dpkg-reconfigure dash` and answer No.
2. Install the host packages listed in the PetaLinux 2025.1 release notes (AMD Answer Record 000037095).
3. Install PetaLinux as a normal user and load its environment in every shell that runs PetaLinux commands:

   ```sh
   ./petalinux-v2025.1-final-installer.run --dir ~/petalinux/2025.1
   source ~/petalinux/2025.1/settings.sh
   ```

The build needs about 100 GB on a Linux file system. On Windows, use WSL2 and keep the repository inside the
WSL file system (for example `~/mclp`), not on `/mnt/c` or `/mnt/d`: the Windows drives
are slow through WSL and do not keep Linux file ownership, which the build relies on.

## 2. Get the repository

```sh
git clone <repository-url> ~/mclp
cd ~/mclp/sw/linux
```

The build runs in this folder. Clone the whole repository, not only `sw/linux`: the `mclp` recipe takes
its sources from `sw/common` and `sw/linux/mclp` through `MCLP_SW_DIR`.

## 3. Hardware description

The project already holds the system device tree and bitstream of this repository's design. Skip this step
unless you changed the design and exported a new XSA (README step 3B).

1. Generate the system device tree from the XSA. `sdtgen` ships with Vitis 2025.1; `-board_dts zc702` adds
   the board's Ethernet PHY, I2C devices and LEDs. Run it from the repository root:

   ```sh
   sdtgen -eval "set_dt_param -xsa build/mclp.xsa -dir build/sdt -board_dts zc702; generate_sdt"
   ```

2. Import it into the project. In the menu that opens, check that DTG Settings -> MACHINE_NAME is `zc702`
   (UG1144 Table 7, a custom design on an AMD evaluation board), then exit and save:

   ```sh
   cd sw/linux
   petalinux-config --get-hw-description ../../build/sdt
   ```

## 4. Build

1. Set the build's parallelism to about 2 GB of RAM per thread, or large compiles fail when memory runs out.
   The values in `project-spec/meta-user/conf/petalinuxbsp.conf` suit a machine with 24 GB:

   ```
   BB_NUMBER_THREADS = "12"
   PARALLEL_MAKE = "-j 12"
   ```

2. Generate the build configuration, then build:

   ```sh
   petalinux-config --silentconfig
   petalinux-build
   ```

   `grep meta-mclp build/conf/bblayers.conf` shows the layer in the configuration. The first build takes
   hours; later builds rebuild only what changed. Output goes to `images/linux/`.

3. Package the boot files and the SD card image:

   ```sh
   petalinux-package boot --u-boot --fpga --force          # BOOT.BIN with FSBL, bitstream and U-Boot
   petalinux-package wic                                    # images/linux/petalinux-sdimage.wic
   ```

`petalinux-build -c mclp` or `petalinux-build -c device-tree` rebuilds one recipe, which is the quick way
to check a change to the layer.

## 5. Boot on the board

SD card (SW16 positions 3 and 4 at 1): write the image as in README step 3A.

```sh
sudo dd if=images/linux/petalinux-sdimage.wic of=/dev/sdX bs=4M conv=fsync status=progress
```

`/dev/sdX` is the SD card; check the name with `lsblk` before writing.

JTAG (SW16 all 0, `hw_server` running on the machine with the cable):

```sh
petalinux-boot jtag --fpga --bitstream images/linux/system.bit --hw_server-url <host>:3121
petalinux-boot jtag --kernel --hw_server-url <host>:3121
```

Log in as `petalinux`; the first login asks for a new password, which `sudo` then uses. Then check the UIO
devices the boot script set up and run the loopback test:

```sh
ls /sys/class/uio                           # uio0 and uio1
cat /sys/class/uio/uio*/name                # dma@40400000, mclp@43c00000
cat /sys/class/uio/uio*/maps/map*/addr      # 0x40400000, 0x3fc00000 (capture ring), 0x43c00000
sudo mclp -t bist
```

## mclp

```
mclp [-t] [command ...]
```

Without a command it runs the interactive console, with the commands of the bare-metal console: `status`,
`w`, `live`, `tare`, `zero`, `cal ...`, `stab`, `wim`, `decim`, `fir`, `raw`, `faults`, `adc`, `selftest`,
`bist`, `info`, `trace`, `rd`, `wr`, `help` (README step 4). With a command it runs that command and exits,
with status 1 if the command reports a failure; settings the command changes are saved to
`/etc/mclp/mclp.cal`.

`/dev/uio*` belongs to root, so the `petalinux` user runs `sudo mclp ...`. At boot, `/etc/init.d/mclp`
runs `mclp init`: it checks the ID register, loads and applies the calibration, and runs the AD7190
power-up list. The root file system is EXT4 on the SD card's second partition (`/dev/mmcblk0p2`), so the
calibration survives a reboot. With INITRD instead (`petalinux-config` -> Image Packaging Configuration),
`/etc` is in RAM and the calibration is lost at power-off.

`-t` prints every register access as it happens, decoded, with the `devmem` command that does the same, and
a heading for each step of a command:

```
[    67.016 ms] ---- BIST check 3: inject ERR on channel 4, only FAULT[4].ERR may set
[    67.016 ms] WR CTRL              <- 0x00000103  enable loopback FAULT_CLEAR tap=0  devmem 0x43C00004 32 0x00000103
[    67.016 ms] WR LOOPBACK_CFG      <- 0x10460042  inject_ERR ch=4 period=4166        devmem 0x43C00054 32 0x10460042
```

How the UIO access is set up: the kernel builds `uio_pdrv_genirq` as a module. It binds devices whose
`compatible` matches its `of_id` parameter, and its device table has one empty entry, so the boot-time device
scan loads it for every device-tree device, before any boot script runs. `mclp-uio.conf` passes `of_id`
to that load. Without it, the module loads without the parameter and binds nothing, and a later
`modprobe ... of_id=generic-uio` does nothing because the module is already loaded.

## On another board

The layer does not depend on the ZC702. For another Zynq-7000 board, create a project from the board's BSP
or the `zynq` template, import the board's hardware description (step 3), copy `meta-mclp` into the project
and add it:

1. `project-spec/configs/config`: `CONFIG_USER_LAYER_0="${PROOT}/meta-mclp"` (or `petalinux-config` ->
   Yocto Settings -> User Layers).
2. `project-spec/meta-user/conf/petalinuxbsp.conf`: `IMAGE_INSTALL:append = " mclp"`, which puts
   `mclp`, its boot script and the module option in the root file system.
3. In `meta-mclp/conf/layer.conf`, point `MCLP_SW_DIR` at the repository's `sw/` folder.

`mclp.dtsi` expects the register block at 0x43C0_0000 on IRQ_F2P[1] and the AXI DMA at 0x4040_0000, as in
the Vivado design; a different address map needs the same change there.
