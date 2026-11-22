# Linux: PetaLinux 2025.1

This folder holds Linux for MCLP on the ZC702:

- a PetaLinux 2025.1 project in the system device tree (SDT) flow
- the `meta-mclp` layer, which gives user space access to the PL
- `mclp`, the Linux console
- `mclpd`, the REST and MQTT service

## What is in this folder

| Path | Purpose |
|---|---|
| `.petalinux/metadata` | PetaLinux project metadata (tool version, project type) |
| `.gitignore` | PetaLinux's ignore list: build products stay out of version control |
| `project-spec/configs/config` | Project configuration: hardware description, boot settings, root file system type, user layers |
| `project-spec/configs/rootfs_config` | Root file system package selection |
| `project-spec/hw-description/` | System device tree from `sdtgen` (`system-top.dts`, `pl.dtsi`, `pcw.dtsi`), the bitstream (`*.bit`) and `ps7_init` |
| `project-spec/meta-user/` | PetaLinux's per-project layer: `conf/petalinuxbsp.conf` (thread limits, `mclp` in the image) and an empty `system-user.dtsi` |
| `meta-mclp/conf/layer.conf` | Declares the layer. `MCLP_SW_DIR` points at the repository's `sw/` for the shared sources. |
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
| `images/linux/` | Build output of `petalinux-build`, not in git |

The console logic (commands, register operations, calibration) is in `sw/common`. The bare-metal console uses
the same code.

A build writes these files, among others, to `images/linux/`:

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
On Ubuntu 24.04 (WSL2 included), the image and the recipes here build, but `petalinux-build --sdk` fails.
PetaLinux's `pseudo` loses track of directories that `tar` 1.35 creates, and the packaging of the SDK's host
tools stops with `uid not found: 1000`. Nothing in this project needs the SDK.

The build needs about 100 GB on a Linux file system. On Windows, use WSL2 and keep the repository in the WSL
file system, for example `~/mclp`. Through WSL, `/mnt/c` and `/mnt/d` are slow and lose Linux file ownership,
which the build needs.

1. Make `/bin/sh` bash: run `sudo dpkg-reconfigure dash` and answer No.
2. Install the host packages listed in the PetaLinux 2025.1 release notes (AMD Answer Record 000037095).
3. Install PetaLinux as a normal user. Load its environment in every shell that runs PetaLinux commands:

   ```sh
   ./petalinux-v2025.1-final-installer.run --dir ~/petalinux/2025.1
   source ~/petalinux/2025.1/settings.sh
   ```

## 2. Get the repository

```sh
git clone <repository-url> ~/mclp
cd ~/mclp/sw/linux
```

The build runs in this folder. Clone the whole repository, because the `mclp` recipe takes its sources from
`sw/common` and `sw/linux/mclp` through `MCLP_SW_DIR`.

## 3. Hardware description

The project already holds the system device tree and bitstream of this repository's design. Do this step only
after you change the design and export a new XSA (main README, Build from source).

1. Generate the system device tree from the XSA. `sdtgen` ships with Vitis 2025.1. `-board_dts zc702` adds the
   board's Ethernet PHY, I2C devices and LEDs. Run it from the repository root:

   ```sh
   sdtgen -eval "set_dt_param -xsa build/mclp.xsa -dir build/sdt -board_dts zc702; generate_sdt"
   ```

2. Import it into the project. In the menu that opens, check that DTG Settings -> MACHINE_NAME is `zc702`
   (UG1144 Table 7, a custom design on an AMD evaluation board). Then exit and save:

   ```sh
   cd sw/linux
   petalinux-config --get-hw-description ../../build/sdt
   ```

   The import regenerates the Linux device tree in `components/plnx_workspace/device-tree`, but it can keep
   the previous one. Before you build, check that the core's node is in it:

   ```sh
   grep -c mclp_core_0 components/plnx_workspace/device-tree/cortexa9-linux.dts
   ```

   If the count is 0, the old tree is still there, and the build would stop with "Label or path mclp_core_0
   not found" in `mclp.dtsi`. Delete the tree and import again:

   ```sh
   rm -rf components/plnx_workspace/device-tree
   petalinux-config --get-hw-description ../../build/sdt
   ```

## 4. Build

1. Set the build's parallelism to about 2 GB of RAM per thread. With more threads, large compiles run out of
   memory and fail. The values in `project-spec/meta-user/conf/petalinuxbsp.conf` suit a machine with 24 GB:

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
   hours. Later builds rebuild only what changed. The output goes to `images/linux/`.

3. Package the boot files and the SD card image:

   ```sh
   petalinux-package boot --u-boot --fpga --force          # BOOT.BIN with FSBL, bitstream and U-Boot
   petalinux-package wic                                    # images/linux/petalinux-sdimage.wic
   ```

To check a change to the layer, rebuild only its recipe with `petalinux-build -c mclp` or
`petalinux-build -c device-tree`.

## 5. Boot on the board

SD card (SW16 positions 3 and 4 at 1): write the `.wic` to the card, or partition the card and copy the files
from `images/linux/` as in the main README (Prebuilt images). `lsblk` shows the card's device name.

```sh
sudo dd if=images/linux/petalinux-sdimage.wic of=/dev/sdX bs=4M conv=fsync status=progress
```

JTAG (SW16 all 0, `hw_server` running on the machine with the cable):

```sh
petalinux-boot jtag --fpga --bitstream images/linux/system.bit --hw_server-url <host>:3121
petalinux-boot jtag --kernel --hw_server-url <host>:3121
```

Log in as `petalinux`. The first login asks for a new password, which `sudo` then uses. Check the UIO devices
that the boot script created, then run the loopback test:

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

Without a command, `mclp` opens the interactive console (`mclp>` prompt). With a command, it runs that command
and exits, with status 1 when the command reports a failure. `/dev/uio*` belongs to root, so run `sudo mclp`.

A command saves every setting that it changes to `/etc/mclp/mclp.cal` at once, tare included. `mclp` loads the
file at every start. The bare-metal console takes the same commands and saves with `cal save`.

| Command | Action |
|---|---|
| `status` | Clocks, sequencer, weight, faults, calibration, filters |
| `w` | One reading |
| `live` | Live reading at 10 Hz with stability, overload and weigh-in-motion events |
| `tare`, `tare clear` | Tare at the current load, or clear it |
| `zero` | Set the no-load zero point |
| `cal ...` | Calibration, below |
| `stab <band> <samples>` | Stability window, band in kg once spanned |
| `wim <enter> <exit> <level>`, `wim off` | Weigh-in-motion thresholds in kg above zero, and the share of the peak (0 to 1) that counts |
| `wim` | The last weigh-in-motion result |
| `nn` | Inference engine state, model (layers, CRC-32 of the model memories) and last result |
| `nn on`, `nn off` | Inference engine on or off after each weigh-in-motion result |
| `nn load [prefix]` | Load a model, below |
| `decim <n>` | RESULT rate 600/n Hz |
| `fir <hz>` | FIR low-pass cutoff, 0.5 to 37 Hz |
| `raw <tap> <n>` | Capture n records through the DMA (tap 0 ADC code, 1 CIC, 2 gain/offset, 3 trim), print CSV |
| `faults`, `faults clear` | Sticky flags per channel: ERR, NOREF, PARITY, STALE, MISMATCH |
| `adc` | Rerun the AD7190 power-up list: reset, ID, zero-scale calibration, stream |
| `selftest` | Burnout currents (open wire), reference detect, internal-short offset and noise per channel |
| `bist` | PL loopback: bit-exact data on all lanes, injected ERR on each channel, injected parity error |
| `info` | Software version, addresses, calibration file |
| `trace on`, `trace off` | Print every register access, decoded, with the equivalent `devmem` command |
| `rd <addr>`, `wr <addr> <value>` | Register access. An address below 0x10000 is an offset from 0x43C0_0000. |

At boot, `/etc/init.d/mclp` runs `mclp init`: ID check, calibration load, AD7190 power-up list. The root file
system is ext4 on the SD card's second partition (`/dev/mmcblk0p2`). With an INITRD root file system instead
(`petalinux-config` -> Image Packaging Configuration), `/etc` is in RAM, and the board loses the calibration at
power-off.

### First start

1. `status`: ID `4D4C0508` (register map version 5, 8 channels), clocks locked, sequencer streaming.
2. `bist`: the loopback emulator replaces the DOUT lines. The test checks the capture path bit for bit, then
   the fault flags of every channel. A failure points at the FPGA image.
3. `selftest`, per channel: `OPEN` is full scale with the burnout currents on (broken cable or load cell).
   `MISSING` is a missing reference (no excitation). A noise figure above the limit points at grounding or
   shielding. The ADCs return to normal operation afterwards.
4. `faults`: flags set during operation. `faults clear` resets them.
   - `ERR`: over-range or open input
   - `NOREF`: missing reference
   - `PARITY`: corrupted word on the cable
   - `STALE`: word read before the conversion finished
   - `MISMATCH`: loopback error

### Calibration

You need one test weight of known mass. Run all steps in one session: the interactive console (`sudo mclp`),
or REST or MQTT commands to `mclpd`. The corner steps keep their measurements in the program's memory, so
separate `sudo mclp cal ...` calls do not share them.

1. With the platform empty, run `cal zero`. It measures each channel for 1 s and writes the offsets, so that
   every channel reads 0 at no load.
2. Place the test weight over each load cell in turn and run `cal corner 0` to `cal corner 7`. Each step
   records the eight channel responses and prints the weight split between the cells.
3. Run `cal solve <kg>`. It fits the corner trims for the same reading at every position, and it sets the span
   (kg per count) from the test weight. Fewer than eight positions work. Trims that the positions do not
   determine stay near 1.
4. On Linux, `mclp` saves after each step. On bare metal, run `cal save` to store the calibration, filter and
   threshold settings in `0:/mclp.cal`.

To re-span later without the corner test, run `cal span <kg>`.

### Daily use

- `zero`, with the platform empty, corrects drift of the no-load reading.
- `tare` subtracts a container until `tare clear`, across restarts.
- `live` shows the weight with the stability flag. `stab <band> <samples>` sets how still the reading must be
  to count as stable.
- `wim <enter> <exit> <level>` sets the weigh-in-motion thresholds. The core averages each load that passes
  over the platform over the weights at or above `level` times its peak (0.93 at reset). `live` and `wim`
  report the result.
- `nn on` makes the inference engine correct each weigh-in-motion result. `live`, `wim` and `nn` show the
  corrected estimate and the correction. `mclp` saves the setting with the calibration.
- `nn load [prefix]` loads a model from `<prefix>_layers.mem`, `<prefix>_bias.mem` and `<prefix>_weights.mem`,
  hex words in the format of `coeff/nn_*.mem`. Without a prefix, it loads `/etc/mclp/nn_*.mem`. `mclp init`
  loads `/etc/mclp/nn_*.mem` at boot when the files exist. Otherwise the bitstream's default model stays. The
  default model is for single axles on a 0.75 m platform with 8 cells.
- `fir <hz>` sets the cutoff. A lower cutoff gives less noise and a slower response. `decim <n>` sets the
  RESULT rate.
- `raw <tap> <n>` records per-channel data for analysis. `raw 1 600` records one second after the CIC.

### Register trace

`-t`, or `trace on` in the console, prints every register access with its decoded fields and the `devmem`
command that does the same. It also prints a heading for each step of a command:

```
[    67.016 ms] ---- BIST check 3: inject ERR on channel 4, only FAULT[4].ERR may set
[    67.016 ms] WR CTRL              <- 0x00000103  enable loopback FAULT_CLEAR tap=0  devmem 0x43C00004 32 0x00000103
[    67.016 ms] WR LOOPBACK_CFG      <- 0x10460042  inject_ERR ch=4 period=4166        devmem 0x43C00054 32 0x10460042
```

## mclpd

```
mclpd [-c /etc/mclp/mclpd.conf]
```

mclpd serves the console commands and live readings over REST (HTTPS) and MQTT (TLS). `/etc/init.d/mclp`
starts it at boot after `mclp init`, and `/etc/init.d/mclp stop` stops it. It links the same `sw/common` code
as `mclp` and returns each command's console output in the JSON reply. The log is `/var/log/mclpd.log`.

`mclp` and `mclpd` take an exclusive lock on `/run/mclp.lock` for every command and reading. They start each
command from the stored settings. A network command waits while `sudo mclp live` runs on the board, and the
reverse.

### Accounts

REST uses HTTP basic authentication. `openssl passwd -6` asks for the password and prints its hash:

```sh
echo "alice:operator:$(openssl passwd -6)" | sudo tee -a /etc/mclp/users
echo "panel:viewer:$(openssl passwd -6)" | sudo tee -a /etc/mclp/users
sudo chmod 600 /etc/mclp/users
```

A viewer reads the weight, faults and settings, and runs the reporting commands: `status`, `info`, `w`, and
`wim`, `nn`, `faults`, `stab`, `decim`, `fir`, `cal show` without arguments. An operator runs every command.
mclpd reads the file on every request. Without accounts, REST answers 401.

### Certificate

At the first start, the init script creates a self-signed certificate, `/etc/mclp/server.crt`, and its key.
Clients trust that file. Or replace both files with a certificate from your own CA and run
`sudo /etc/init.d/mclp restart`.

### REST

Port 443.

| Request | Answer | Role |
|---|---|---|
| `GET /api/v1/weight` | `{"value":12.345,"unit":"kg","stable":true,"overload":false,"seq":..,"time_ms":..,"wim":{..},"nn":{..}}` | viewer |
| `GET /api/v1/faults` | `{"channels":[[],["ERR"],..],"any":true}` | viewer |
| `GET /api/v1/settings` | Calibration, FIR, decimation, stability, weigh-in-motion and inference (`"nn":{"enabled":..}`) settings | viewer |
| `POST /api/v1/cmd` with `{"cmd":"<command>"}` | `{"cmd":..,"ok":true,"output":"<console output>"}` | viewer for the reporting commands, else operator |

```sh
scp petalinux@<board>:/etc/mclp/server.crt .
curl --cacert server.crt -u alice https://<board>/api/v1/weight
curl --cacert server.crt -u alice -d '{"cmd":"tare"}' https://<board>/api/v1/cmd
```

curl checks the certificate against the host name in the URL. Use the host name in the certificate (the
board's hostname, `mclp` by default), or `-k` while testing.

### MQTT

Set the broker in `/etc/mclp/mclpd.conf`, then run `sudo /etc/init.d/mclp restart`:

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
server and a set RTC, the connection fails with "A TLS error occurred". mclpd retries after 2 s and doubles the
interval up to 60 s. It connects when the clock is right.

| Topic | Payload |
|---|---|
| `mclp/<device>/weight` | As `GET /api/v1/weight` without `wim` and `nn`, on each RESULT update, at most `publish_hz` per second (QoS 0) |
| `mclp/<device>/wim` | `{"value":..,"unit":"kg","samples":..,"seconds":..}` per weigh-in-motion result (QoS 1) |
| `mclp/<device>/inference` | `{"value":..,"unit":"kg","correction":..,"seq":..}` per inference: the corrected weigh-in-motion estimate and the correction as a fraction (QoS 1) |
| `mclp/<device>/faults` | As `GET /api/v1/faults`, on change (QoS 1, retained) |
| `mclp/<device>/status` | `online`, or `offline` when mclpd stops or loses the connection (QoS 1, retained) |
| `mclp/<device>/cmd` | Publish a console command line here, for example `tare` or `cal corner 3` |
| `mclp/<device>/cmd/result` | The reply, as from `POST /api/v1/cmd` (QoS 1) |

mclpd accepts every command on the `cmd` topic. Restrict publish rights on it to the clients that may operate
the scale (broker ACLs). mclpd refuses `live` there and over REST.

## UIO

The kernel builds `uio_pdrv_genirq` as a module. The module binds devices whose `compatible` matches its
`of_id` parameter. Its device table has one empty entry, so the boot-time device scan loads it for every
device-tree device, before any boot script runs. `mclp-uio.conf` passes `of_id` to that load. Without it, the
module loads without the parameter and binds nothing. A later `modprobe ... of_id=generic-uio` then does
nothing, because the module is already loaded.

## On another board

The layer does not depend on the ZC702. For another Zynq-7000 board:

1. Create a project from the board's BSP or the `zynq` template.
2. Import the board's hardware description (step 3).
3. Copy `meta-mclp` into the project.
4. Add the layer in `project-spec/configs/config`: `CONFIG_USER_LAYER_0="${PROOT}/meta-mclp"` (or
   `petalinux-config` -> Yocto Settings -> User Layers).
5. Add `IMAGE_INSTALL:append = " mclp"` to `project-spec/meta-user/conf/petalinuxbsp.conf`. It puts `mclp`,
   its boot script and the module option in the root file system.
6. In `meta-mclp/conf/layer.conf`, point `MCLP_SW_DIR` at the repository's `sw/` folder.

`mclp.dtsi` expects the register block at 0x43C0_0000 on IRQ_F2P[1] and the AXI DMA at 0x4040_0000, as in the
Vivado design. A different address map needs the same change in `mclp.dtsi`.
