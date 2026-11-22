# Linux: PetaLinux 2025.1

Linux for MCLP on the ZC702: a PetaLinux 2025.1 project in the system device tree (SDT) flow,
the `meta-mclp` layer that gives user space access to the PL, `mclp`, the Linux console, and `mclpd`,
the REST and MQTT service. The
sections below build the SD card image from this folder, boot it, and document `mclp` and `mclpd`.

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
| `meta-mclp/recipes-apps/mclp/mclp.bb` | Builds `mclp` and `mclpd` from `sw/common` and `mclp/`, installs them with the boot script, the module option and the mclpd settings |
| `meta-mclp/recipes-apps/mclp/files/mclp.init` | Boot script (`/etc/init.d/mclp`): starts `ntpd` (writes each sync to the RTC), loads the UIO driver, runs `mclp init`, creates the HTTPS certificate on the first start, starts `mclpd` |
| `meta-mclp/recipes-apps/mclp/files/mclpd.conf` | `/etc/mclp/mclpd.conf`: HTTPS port, certificate, accounts file, MQTT broker and credentials, time servers |
| `meta-mclp/recipes-core/busybox/` | Turns on busybox `ntpd` (`ntpd.cfg`) |
| `meta-mclp/recipes-apps/mclp/files/mclp-uio.conf` | `/etc/modprobe.d/mclp-uio.conf`: makes the UIO driver bind `generic-uio` nodes |
| `mclp/main.c` | `mclp`: argument parsing, keyboard input |
| `mclp/mclpd.c` | `mclpd`: HTTPS server (libmicrohttpd), MQTT client (libmosquitto), accounts, JSON readings |
| `mclp/backend.c` | Shared by both: register access through UIO, the calibration file, the lock on `/run/mclp.lock` |
| `mclp/Makefile` | Builds both with the compiler in `CC` (the recipe passes the cross compiler) |
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

The build needs about 100 GB on a Linux file system. On Windows, use WSL2 and keep the repository in the WSL
file system, for example `~/mclp`. Through WSL, `/mnt/c` and `/mnt/d` are slow and lose Linux file ownership,
which the build needs.

## 2. Get the repository

```sh
git clone <repository-url> ~/mclp
cd ~/mclp/sw/linux
```

The build runs in this folder. Clone the whole repository. The `mclp` recipe takes its
sources from `sw/common` and `sw/linux/mclp` through `MCLP_SW_DIR`.

## 3. Hardware description

The project already holds the system device tree and bitstream of this repository's design. Skip this step
unless you changed the design and exported a new XSA (main README, Build from source).

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

   The import regenerates the Linux device tree in `components/plnx_workspace/device-tree`, but it can keep
   the previous one. Check that the core's node is in it before you build:

   ```sh
   grep -c mclp_core_0 components/plnx_workspace/device-tree/cortexa9-linux.dts
   ```

   0 means the old tree is still there (the build would stop with "Label or path mclp_core_0 not found" in
   `mclp.dtsi`). Delete it and import again:

   ```sh
   rm -rf components/plnx_workspace/device-tree
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

SD card (SW16 positions 3 and 4 at 1): write the `.wic`, or partition the card and copy the files from
`images/linux/` as in the main README (Prebuilt images). `lsblk` shows the card's device name.

```sh
sudo dd if=images/linux/petalinux-sdimage.wic of=/dev/sdX bs=4M conv=fsync status=progress
```

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

Without a command, `mclp` opens the interactive console (`mclp>` prompt). With a command it runs that command
and exits, with status 1 when the command reports a failure. `/dev/uio*` belongs to root: run `sudo mclp`.
A command saves every setting it changes to `/etc/mclp/mclp.cal` at once, tare included. `mclp` loads the
file at every start. The bare-metal console takes the same commands and saves with `cal save`.

| Command | Action |
|---|---|
| `status` | Clocks, sequencer, weight, faults, calibration, filters |
| `w`, `live` | One reading; live reading at 10 Hz with stability, overload and weigh-in-motion events |
| `tare`, `tare clear`, `zero` | Tare at the current load; set the no-load zero point |
| `cal ...` | Calibration, below |
| `stab <band> <samples>` | Stability window; band in kg once spanned |
| `wim <enter> <exit> <level>`, `wim off` | Weigh-in-motion thresholds in kg above zero and the share of the peak (0 to 1) that counts; without arguments, the last result |
| `decim <n>`, `fir <hz>` | RESULT rate 600/n Hz; FIR low-pass cutoff, 0.5 to 37 Hz |
| `raw <tap> <n>` | Capture n records through the DMA (tap 0 ADC code, 1 CIC, 2 gain/offset, 3 trim), print CSV |
| `faults`, `faults clear` | Sticky flags per channel: ERR, NOREF, PARITY, STALE, MISMATCH |
| `adc` | Rerun the AD7190 power-up list: reset, ID, zero-scale calibration, stream |
| `selftest` | Burnout currents (open wire), reference detect, internal-short offset and noise per channel |
| `bist` | PL loopback: bit-exact data on all lanes, injected ERR on each channel, injected parity error |
| `info` | Software version, addresses, calibration file |
| `trace on`, `trace off` | Print every register access, decoded, with the equivalent `devmem` command |
| `rd <addr>`, `wr <addr> <value>` | Register access. An address below 0x1000 is an offset from 0x43C0_0000. |

At boot, `/etc/init.d/mclp` runs `mclp init`: ID check, calibration load, AD7190 power-up list. The root file
system is ext4 on the SD card's second partition (`/dev/mmcblk0p2`). With INITRD instead (`petalinux-config`
-> Image Packaging Configuration), `/etc` is in RAM and the calibration is lost at power-off.

### First start

1. `status`: ID `4D4C0508` (register map version 5, 8 channels), clocks locked, sequencer streaming.
2. `bist`: the loopback emulator replaces the DOUT lines. The test checks the capture path bit for bit, then
   the fault flags of every channel. A failure points at the FPGA image.
3. `selftest`, per channel: `OPEN` is full scale with the burnout currents on (broken cable or load cell).
   `MISSING` is a missing reference (no excitation). A noise figure above the limit points at grounding or
   shielding. The ADCs return to normal operation afterwards.
4. `faults`: flags set during operation. `ERR` over-range or open input, `NOREF` missing reference, `PARITY`
   corrupted word on the cable, `STALE` word read before the conversion finished, `MISMATCH` loopback error.
   `faults clear` resets them.

### Calibration

One test weight of known mass, in one session: the interactive console (`sudo mclp`), or REST or MQTT
commands to `mclpd`. The corner steps keep their measurements in the program's memory. Separate
`sudo mclp cal ...` calls do not share them.

1. `cal zero`, platform empty. Measures each channel for 1 s and writes the offsets: every channel reads 0 at
   no load.
2. `cal corner 0` to `cal corner 7`, test weight over each load cell in turn. Each step records the eight
   channel responses and prints the weight split between the cells.
3. `cal solve <kg>`. Fits the corner trims for the same reading at every position and sets the span (kg per
   count) from the test weight. Fewer than eight positions work; trims the positions do not determine stay
   near 1.
4. Linux saves after each step. On bare metal, `cal save` stores the calibration, filter and threshold
   settings in `0:/mclp.cal`.

`cal span <kg>` re-spans later without the corner test.

### Daily use

- `zero`, platform empty: corrects drift of the no-load reading.
- `tare`: subtracts a container until `tare clear`, across restarts.
- `live`: weight with the stability flag. `stab <band> <samples>` sets how still the reading must be to count
  as stable.
- `wim <enter> <exit> <level>`: weigh-in-motion. A load passing over the platform is averaged over the weights
  at or above `level` times its peak (0.93 at reset) and reported in `live` and `wim`.
- `fir <hz>`: a lower cutoff gives less noise and a slower response. `decim <n>`: RESULT rate.
- `raw <tap> <n>`: per-channel data for analysis. `raw 1 600` records one second after the CIC.

### Register trace

`-t`, or `trace on` in the console, prints every register access with its decoded fields, the `devmem`
command that does the same, and a heading for each step of a command:

```
[    67.016 ms] ---- BIST check 3: inject ERR on channel 4, only FAULT[4].ERR may set
[    67.016 ms] WR CTRL              <- 0x00000103  enable loopback FAULT_CLEAR tap=0  devmem 0x43C00004 32 0x00000103
[    67.016 ms] WR LOOPBACK_CFG      <- 0x10460042  inject_ERR ch=4 period=4166        devmem 0x43C00054 32 0x10460042
```

## mclpd

```
mclpd [-c /etc/mclp/mclpd.conf]
```

REST over HTTPS and MQTT over TLS for the console commands and live readings. `/etc/init.d/mclp` starts it
at boot after `mclp init`; `/etc/init.d/mclp stop` stops it. It links the same `sw/common` code as `mclp` and
returns each command's console output in the JSON reply. `mclp` and `mclpd` take an exclusive lock on
`/run/mclp.lock` for every command and reading, and start each command from the stored settings. A network
command waits while `sudo mclp live` runs on the board, and the reverse. Log: `/var/log/mclpd.log`.

### Accounts

REST uses HTTP basic authentication. `openssl passwd -6` asks for the password and prints its hash:

```sh
echo "alice:operator:$(openssl passwd -6)" | sudo tee -a /etc/mclp/users
echo "panel:viewer:$(openssl passwd -6)" | sudo tee -a /etc/mclp/users
sudo chmod 600 /etc/mclp/users
```

A viewer reads the weight, faults and settings, and runs the reporting commands: `status`, `info`, `w`, and
`wim`, `faults`, `stab`, `decim`, `fir`, `cal show` without arguments. An operator runs every command.
mclpd reads the file on every request. Without accounts, REST answers 401.

### Certificate

The init script creates a self-signed certificate, `/etc/mclp/server.crt`, and its key at the first start.
Clients trust that file, or you replace both files with a certificate from your own CA and run
`sudo /etc/init.d/mclp restart`.

### REST

Port 443.

| Request | Answer | Role |
|---|---|---|
| `GET /api/v1/weight` | `{"value":12.345,"unit":"kg","stable":true,"overload":false,"seq":..,"time_ms":..,"wim":{..}}` | viewer |
| `GET /api/v1/faults` | `{"channels":[[],["ERR"],..],"any":true}` | viewer |
| `GET /api/v1/settings` | Calibration, FIR, decimation, stability and weigh-in-motion settings | viewer |
| `POST /api/v1/cmd` with `{"cmd":"<command>"}` | `{"cmd":..,"ok":true,"output":"<console output>"}` | viewer for the reporting commands, else operator |

```sh
scp petalinux@<board>:/etc/mclp/server.crt .
curl --cacert server.crt -u alice https://<board>/api/v1/weight
curl --cacert server.crt -u alice -d '{"cmd":"tare"}' https://<board>/api/v1/cmd
```

curl checks the certificate against the host name in the URL. Use the name the certificate was made for (the
board's hostname, `mclp` by default), or `-k` while testing.

### MQTT

Set the broker in `/etc/mclp/mclpd.conf`, then `sudo /etc/init.d/mclp restart`:

```
mqtt_host = broker.example.com
mqtt_port = 8883
mqtt_ca = /etc/mclp/broker-ca.crt      # CA that signed the broker's certificate
mqtt_user = scale-01
mqtt_password = ...
device = scale-01                      # topic level and client ID; default: the hostname
publish_hz = 10
ntp_server = pool.ntp.org              # empty: no NTP
```

TLS checks the broker's certificate against the board's clock. The boot script starts `ntpd` with
`ntp_server` and writes each sync to the board's RTC, which sets the clock at the next boot. Without a time
server and a set RTC, the connection fails with "A TLS error occurred". mclpd retries every 2 s, doubling to
60 s, and connects once the clock is right.

| Topic | Payload |
|---|---|
| `mclp/<device>/weight` | As `GET /api/v1/weight` without `wim`, on each RESULT update, at most `publish_hz` per second (QoS 0) |
| `mclp/<device>/wim` | `{"value":..,"unit":"kg","samples":..,"seconds":..}` per weigh-in-motion result (QoS 1) |
| `mclp/<device>/faults` | As `GET /api/v1/faults`, on change (QoS 1, retained) |
| `mclp/<device>/status` | `online`; `offline` when mclpd stops or loses the connection (QoS 1, retained) |
| `mclp/<device>/cmd` | Publish a console command line here, for example `tare` or `cal corner 3` |
| `mclp/<device>/cmd/result` | The reply, as from `POST /api/v1/cmd` (QoS 1) |

mclpd accepts every command on the `cmd` topic. Restrict publish rights on it to the clients that may operate
the scale (broker ACLs). `live` is refused there and over REST.

## UIO

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
