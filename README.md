# Minimal Debian 13 for RIPE Atlas Probe v5

Build and install a small Debian ARM64 system on the RIPE Atlas v5, keeping the existing CZ.NIC secure firmware and U-Boot. This is a community conversion guide, not an official RIPE image. Replacing the Atlas filesystem removes the probe software and its local data. Save a verified factory backup before installing.

**Default login: `atlas` / `Ch@nge!Me(26)`. Change this password on the first boot through UART.** The password is expired in the image. SSH stays disabled until you complete that console password change, then accepts your new password or an installed public key. Root login is locked; use `sudo` with your new password.

The guide covers hardware, builds from scratch, backups, RAM rescue, installation, first boot, persistent boot, maintenance, and recovery. Commands labeled **PC**, **build host**, **U-Boot**, **rescue**, or **Debian** belong on that system. Do not paste a Linux command into U-Boot or a U-Boot command into Linux.

## Contents

1. [Hardware and UART](#1-hardware-and-uart)
2. [What the image contains](#2-what-the-image-contains)
3. [Build from scratch](#3-build-from-scratch)
4. [GitHub Actions and publication](#4-github-actions-and-publication)
5. [Prepare the transfer server](#5-prepare-the-transfer-server)
6. [Boot the RAM rescue](#6-boot-the-ram-rescue)
7. [Back up the factory eMMC](#7-back-up-the-factory-emmc)
8. [Install the root filesystem](#8-install-the-root-filesystem)
9. [Trial boot and first login](#9-trial-boot-and-first-login)
10. [Make Debian boot automatically](#10-make-debian-boot-automatically)
11. [Maintenance and further size reductions](#11-maintenance-and-further-size-reductions)
12. [Troubleshooting and recovery](#12-troubleshooting-and-recovery)
13. [Design references and validation](#13-design-references-and-validation)

## 1. Hardware and UART

This guide is for **RIPE Atlas Probe v5**, with Marvell Armada 3720, two Cortex-A53 cores, 512 MiB RAM, approximately 4 GB eMMC, and gigabit Ethernet. Check that your board matches. Older probe generations need different images.

You need:

- Stable USB power for the probe. Its USB connector supplies power; it is not a USB serial console.
- An adapter with genuine **1.8 V UART logic** on both TX and RX, jumper wires, and a terminal program.
- Ethernet on a LAN with DHCP, plus a PC/server providing TFTP and optionally HTTP.
- A PC with OpenSSH and Python 3.12+ for the helpers, and at least 4 GiB free for a factory backup.
- For source builds, a native ARM64 Linux host with Docker already installed. An ARM64 cloud VM or the GitHub runner below works.

The board header is documented in the [OpenWrt support commit](https://github.com/openwrt/openwrt/commit/42b10de18d65963cc83dca5ee3d58f01836a7221):

| Probe pin | Signal | Connect to adapter |
|---|---|---|
| 1 | GND | GND |
| 2 | +1.8 V | Leave disconnected |
| 5 | TX, 1.8 V | RX |
| 6 | RX, 1.8 V | TX |

Identify pin 1 from the board/header marking or the original board documentation; do not assume which corner is pin 1. Connect ground and cross TX/RX. Power the probe normally over USB. **Do not connect adapter VCC to the probe.** A board's 1.8 V power pin does not automatically change an adapter's signal voltage.

An UNO+WiFi R3/CH340G board with 5 V or 3.3 V UART is unsuitable for a direct connection. An FT232RL module is usable only when its 1.8 V setting actually changes **VCCIO and TX/RX logic**, rather than just a power output. Check the module documentation and, if uncertain, measure idle TX voltage before connecting it. A clearly specified 1.8 V adapter avoids that ambiguity.

Set the terminal to **115200 baud, 8 data bits, no parity, 1 stop bit, no flow control**. A local TX/RX loopback test of the adapter can check the PC driver and terminal; remove the loopback before connecting the probe. Start terminal logging, power on, and press a key during the U-Boot countdown.

## 2. What the image contains

| Feature | Configuration |
|---|---|
| Distribution | Debian 13 `trixie`, ARM64, `mmdebstrap --variant=minbase` |
| Kernel | Linux 6.18.54, custom `-atlas-v5` configuration |
| Storage | Single 1 GiB ext4 filesystem image, expanded to the existing eMMC partition during installation |
| Boot | Existing U-Boot loads `/boot/Image` and the board DTB directly; no installed initramfs needed |
| Networking | systemd-networkd, DHCP, IPv6 router advertisements; static DNS 1.1.1.1 and 9.9.9.9 |
| SSH | Dropbear, port 22, root login disabled, starts after first password change |
| User | `atlas`, UID 1000, normal password-protected sudo |
| Memory | LZ4 zram swap sized to half detected RAM |
| Logs | Volatile journal limited to 8 MiB |
| Locale/time | C.UTF-8, UTC, systemd-timesyncd |

Documentation, manual pages, most locales, recommendations, package caches, and unrelated kernel hardware drivers are omitted. Copyright files remain. eMMC, ext4, Ethernet, UART, required clocks/regulators, and firmware interfaces are built into the kernel. zram, WireGuard, TUN, and nftables support are available. Small virtio and PL011 drivers allow automated QEMU testing.

This configuration omits USB host/device drivers, Wi-Fi, Bluetooth, PCI, graphics, audio, and several other subsystems. It also disables the Linux watchdog driver: stopping the firmware watchdog in U-Boot is therefore required on **every boot**. Use `scripts/kernel-config.sh` if you need to change those choices.

There is no D-Bus daemon or normal logind session management. Use **`sudo systemctl`**, and inspect timesyncd's journal rather than relying on `timedatectl`. Add packages later if your application needs a broader system.

The four probe payloads are:

| File | Purpose |
|---|---|
| `Image` | ARM64 Linux kernel, used for the initial network boot |
| `armada-3720-atlas-v5.dtb` | Device tree for this board |
| `atlas-v5-rescue.cpio.gz` | RAM-only installation/backup environment |
| `atlas-v5-debian13-rootfs.ext4.zst` | Compressed **filesystem for one partition**, not a whole-disk image |

`atlas-v5-probe-files.zip` contains these files, their `SHA256SUMS`, and this guide. The rootfs already contains its installed kernel, DTB, and modules. Keep all four files from the **same build**: the rescue installer embeds the SHA256 of its matching rootfs and rejects a different image.

## 3. Build from scratch

### Native ARM64 Linux host

Use an ARM64 Linux host with Docker access, roughly 8 GiB available RAM, and at least 8 GiB free disk space. A four-core host is sufficient. Package installation and compiler/QEMU execution happen inside a disposable Debian container. The build does not run host `apt` or alter host services.

**Build host:** clone your copy of this repository, or copy the source directory to the host, then run:

```bash
cd atlas-v5-debian
uname -m                 # must print aarch64
docker version
bash build.sh
```

The build refuses to overwrite an existing `dist/`; move an earlier output elsewhere before rebuilding. `build.env` pins the Debian builder digest, Linux version, and source SHA256. Debian package repositories provide current signed trixie updates. Consequently this recipe is repeatable but **not byte-for-byte reproducible**: package updates, build time, filesystem UUID, and password salt can differ between builds.

`build.sh` creates a unique `.build-*` directory and container. The container has a limit of three CPUs, 8 GiB RAM, and 512 processes by default. `SYS_ADMIN` and an unconfined AppArmor profile permit mmdebstrap's namespace/mount operations inside the container. Only its own scratch directory is bind-mounted. On completion it copies verified output to `dist/`, removes its container and scratch directory, and leaves the Docker base image cached. It never prunes unrelated Docker resources.

Optional limits, **build host**:

```bash
JOBS=2 BUILD_CPUS=2 BUILD_MEMORY=6g bash build.sh
```

The stages are:

1. Install build dependencies inside the container and verify the pinned Linux archive hash.
2. Generate the Armada 3720 kernel configuration, compile the kernel/DTB/modules, and create `linux-image-atlas-v5_..._arm64.deb`.
3. Bootstrap Debian minbase and install that kernel package.
4. Configure networking, zram, logs, the `atlas` account, expired initial password, and SSH startup gate.
5. Remove machine ID, random seed, and SSH host keys; create and check the ext4 filesystem.
6. Boot a **snapshot** in a 512 MiB, two-core Cortex-A53 QEMU guest. Verify console password expiry, SSH gating, new-password authentication, rejection of the old password, packages, APT, DHCP/DNS, services, and zram. Check that the pristine image hash did not change.
7. Compress the pristine rootfs, build its matching rescue initramfs, and boot that rescue in QEMU. Verify the paired image download/hash, whole-disk installer refusal, and filesystem expansion on a disposable virtual disk.
8. Check kernel-header extent and RAM load ranges, then create manifests and the transfer ZIP.

Check the output, **build host**:

```bash
cd dist
sha256sum -c SHA256SUMS
cat build-info.txt
cat qa-image.txt
cat qa-rescue.txt
```

`dist/` also contains the kernel `.deb`, rootfs `.tar.zst`, package list, kernel configuration, board DTS, and QA reports. The tar archive is useful for inspection/customization; use the **ext4.zst** for this installation guide. Do not write the tar archive to a block device.

For a failed local build, inspect `dist/build.log`. The remote helper downloads an unsuccessful build into `failed-dist/` for diagnosis; those files have not passed release QA. Move an earlier output aside before retrying. `KEEP_WORK=1 bash build.sh` retains the local build scratch directory when you need to debug it; keep that directory out of Git.

### Optional public keys

The public build embeds **no personal authorized keys**. For your own build, place one or more OpenSSH public-key lines in `local/authorized_keys` before running `build.sh`. That file is ignored by Git. Only public keys belong there; never put a private key in the project or image.

These keys allow rescue SSH and, after the required console password change, normal `atlas` SSH. The public GitHub Actions build has no such file. For that build, add your rescue public key through the serial shell as explained below.

### Build on a remote ARM64 VM

For example, from a PC whose SSH config already defines an ARM64 host alias:

```bash
python tools/remote-build.py --host oci-hyd --out ../atlas-release
```

The helper uploads this source, builds in a unique remote cache directory, downloads the result, checks every release hash, then removes its scratch directory and container. If it pulled a previously absent builder image, it attempts to remove that specific image too. It records before/after package, service configuration, and Docker inventories outside the source tree. Independent changes made by other users/services are reported, not reverted.

SSH trust and authentication must already work with that alias. The helper does not install Docker or packages on the VM. A build leaves the VM's base OS intact, but building necessarily uses temporary storage, CPU, RAM, network, and Docker state while running. It is not a zero-I/O operation.

### Change the kernel or base configuration

Update `KERNEL_VERSION` and `KERNEL_SHA256` together using the corresponding official kernel.org source archive/checksum. Review `scripts/kernel-config.sh` and the resulting `.config`; indispensable root-device drivers must remain built in. Rebuild **everything**, including the rescue, and rerun QA. A different kernel may change RAM extent/relocation rules: the packaging script intentionally fails if the old load-address assumptions no longer hold.

Customization lives in `scripts/customize-rootfs.sh`; dependencies live in `scripts/build-image.sh` and `scripts/build-all.sh`. Never distribute an image after booting it normally and retaining its identity, SSH host keys, or a personal password. The build's snapshot QA avoids modifying the distributable filesystem.

## 4. GitHub Actions and publication

The supplied `.github/workflows/build.yml` uses the standard **`ubuntu-24.04-arm`** runner and invokes the same `bash build.sh` recipe. It runs on changes to build inputs on `main`, and through **Actions → Build Atlas image → Run workflow**. It requires no OCI credentials or repository secrets. Only a small transfer ZIP and QA/build reports are uploaded; artifact retention is one day. Download artifacts before they expire.

As checked on 2026-10-04, GitHub provides standard ARM64 Linux runners for public repositories and free standard-runner compute for public repositories. Artifact storage still has limits; short retention reduces storage usage. Private repositories use their plan's Actions allowance and may incur charges if billing is enabled. The workflow itself cannot guarantee a zero bill under every account policy. See [GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) and [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

The recipe is tested on an ARM64 Docker host. A GitHub-hosted run needs to be verified after you publish the repository; no workflow has been dispatched from this local project.

To publish, upload **this source directory only**. Do not upload your entire working folder, factory backups, personal SSH configs, `local/`, `.build-*`, or previous images containing a personal account/key.

**PC, in this source directory:**

```bash
git init -b main
git add .
git status --short
git diff --cached --stat
git commit -m "Add minimal Debian build and installation guide for Atlas v5"
git remote add origin https://github.com/YOUR-ACCOUNT/YOUR-REPOSITORY.git
git push -u origin main
```

Create the empty repository on GitHub first. Review staged files before committing. `dist/` is ignored; attach the tested transfer ZIP to a GitHub Release manually, rather than committing binary images. Keep the complete build metadata/source for each release. Debian packages and the Linux kernel retain their own licenses; rebuilding should accompany redistribution. This project's scripts and documentation use the [MIT license](LICENSE). This project adds no RIPE Atlas software, vendor firmware, or factory backup to the public image.

## 5. Prepare the transfer server

The examples use **TFTP/HTTP server `192.168.1.12`** and a probe DHCP address such as `192.168.1.78`. Replace these addresses for your LAN. The server and probe must be reachable over Ethernet.

Extract `atlas-v5-probe-files.zip` into a directory. Verify `SHA256SUMS` before serving anything.

For example, **PC/server**:

```bash
python -m zipfile -e atlas-v5-probe-files.zip probe-files
```

**Linux PC/server:**

```bash
cd probe-files
sha256sum -c SHA256SUMS
```

**Windows PowerShell**, from the extracted directory:

```powershell
Get-Content SHA256SUMS | ForEach-Object {
    $hash, $name = $_ -split '\s+', 2
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $name).Hash.ToLowerInvariant()
    if ($actual -ne $hash) { throw "Checksum mismatch: $name" }
    Write-Host "OK $name"
}
```

Configure an existing TFTP server to use this directory. It must allow read access to the four filenames exactly as listed. Permit the TFTP daemon's UDP traffic in the server firewall: TFTP starts on UDP 69 and uses additional UDP transfer ports. Restrict access to your LAN. Do not run two TFTP servers on the same address/port.

If you need a temporary TFTP server on a **separate Debian/Ubuntu LAN server**, the following example uses the [tftpd-hpa daemon options](https://manpages.debian.org/trixie/tftpd-hpa/in.tftpd.8.en.html). These server package commands are not part of the isolated image build on OCI.

**LAN server**, from the parent of `probe-files`:

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends tftpd-hpa
sudo systemctl stop tftpd-hpa
sudo install -d -m 755 /srv/tftp
sudo install -m 644 probe-files/Image probe-files/armada-3720-atlas-v5.dtb \
    probe-files/atlas-v5-rescue.cpio.gz probe-files/atlas-v5-debian13-rootfs.ext4.zst /srv/tftp/
sudo /usr/sbin/in.tftpd --foreground --user tftp --secure \
    --address 192.168.1.12:69 --blocksize 512 --port-range 20000:20020 /srv/tftp
```

Use your server's actual LAN address. Allow UDP 69 and UDP 20000–20020 from your LAN when using this port-range example. Keep the foreground daemon running during transfers; Ctrl+C stops it. If a TFTP service already works, use it and skip this alternative setup. A 512-byte server block limit complements the client setting but does not replace the probe's `dcache off` workaround.

For the rootfs transfer to the rescue, HTTP is usually easier than TFTP for a larger file. **PC/server** with Python installed:

```bash
python -m http.server 8000 --bind 0.0.0.0 --directory probe-files
```

Run that command from the parent of `probe-files`, or use `--directory .` inside the extracted directory. Allow TCP 8000 from the probe. This is a temporary LAN file server; stop it after installation.

## 6. Boot the RAM rescue

Interrupt autoboot and save the complete serial log. **U-Boot:**

```text
printenv
mmc list
mmc dev 0 0
mmc part
wdt list
```

On the tested board, MMC device 0 is the eMMC; its existing partition 1 starts at sector 16. Do not repartition the eMMC just because the first partition starts unusually early. Check your own device/partition layout.

The firmware starts a 60-second watchdog. Stop it before entering Linux. A fresh reset restarts it. For network transfers, disable the U-Boot data cache before DHCP to avoid the receive failures observed with this vendor U-Boot.

**U-Boot, after each reset:**

```text
wdt dev watchdog-timer@8300
wdt stop && echo Watchdog stopped
setenv kernel_addr_r 0x06000000
setenv fdt_addr_r 0x05f00000
setenv ramdisk_addr_r 0x08000000
setenv tftpblocksize 512
setenv tftpwindowsize 1
dcache off
setenv autoload no
dhcp
setenv serverip 192.168.1.12
ping ${serverip}
tftpboot ${kernel_addr_r} Image
tftpboot ${ramdisk_addr_r} atlas-v5-rescue.cpio.gz
setenv atlas_rescue_size ${filesize}
tftpboot ${fdt_addr_r} armada-3720-atlas-v5.dtb
setenv bootargs 'console=ttyMV0,115200n8 rdinit=/init'
booti ${kernel_addr_r} ${ramdisk_addr_r}:${atlas_rescue_size} ${fdt_addr_r}
```

Every TFTP transfer must finish with `done` and a nonzero `Bytes transferred`. **Capture `${filesize}` immediately after loading the rescue**, before loading the DTB, because each transfer overwrites that variable. Do not boot after an incomplete transfer. If DHCP is unavailable, use a suitable static `ipaddr`, `netmask`, `gatewayip`, and `serverip` instead.

The corrected addresses avoid the firmware's PSCI reservation at `0x04000000..0x041fffff` and TEE reservation at `0x04400000..0x053fffff`. The earlier kernel address `0x05000000` and DTB address `0x04f00000` overlap that TEE region. This can produce `reserving fdt memory region failed` and failed Linux reserved-memory messages even if Linux reaches a shell. Use the corrected addresses above.

The rescue prints a root SSH host-key fingerprint and opens a serial root shell. It uses RAM only and **does not mount or modify eMMC automatically**. Wait for DHCP; the PHY can take several seconds to establish link.

**Rescue:**

```bash
uname -r
ip addr
lsblk -b -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
blkid
blockdev --getsize64 /dev/mmcblk0p1
cat /sys/class/block/mmcblk0p1/start
cat /sys/class/block/mmcblk0p1/size
```

On the tested 4 GB eMMC, the user disk is `3909091328` bytes, partition 1 is `3909083136` bytes, and boot0/boot1 are 4 MiB each. Sizes/layout can differ: inspect before writing. The rescue's serial shell may report “no job control”; that warning is harmless.

## 7. Back up the factory eMMC

Keep the backup on your PC, not just on the probe. The helper reads the **entire eMMC user disk plus both eMMC boot areas**, checks the byte count, and compares each streamed file's SHA256 with the source device. It uses binary Python I/O to avoid Windows PowerShell redirection corrupting a disk image. It refuses mounted eMMC.

For the public rescue image, install your PC's **public** key through UART. On your PC, inspect an existing `.pub` file or generate a key with `ssh-keygen -t ed25519`. Paste its single public-key line below.

**Rescue, via UART:**

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'EOF'
ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY your-key-comment
EOF
chmod 600 /root/.ssh/authorized_keys
```

Do not paste the literal placeholder and do not paste a private key. No restart is needed: Dropbear reads the authorized keys during login. Rescue SSH is **root, port 2222, public-key only**; the default `atlas` password is for installed Debian, not rescue.

**PC:** connect once and compare the shown fingerprint with the one printed on UART before trusting it:

```bash
ssh -p 2222 root@192.168.1.78
```

Exit that SSH session, then **PC, in the source directory**:

```bash
python tools/probe-backup.py --host 192.168.1.78 --out ../factory-backup --device /dev/mmcblk0
```

Use a new output directory; the helper refuses to overwrite existing backups. If your key needs a custom path or isolated known-hosts file, provide an OpenSSH config through `--ssh-config PATH`. The helper uses strict existing host trust and batch public-key authentication; unlock your key in ssh-agent first if it has a passphrase.

Expect `mmcblk0.img`, `mmcblk0boot0.img`, `mmcblk0boot1.img`, `SHA256SUMS`, and storage inventory. Verify the manifest again locally and save your full UART log, `printenv`, firmware versions, and header wiring notes alongside it. Copy these files to a second location before installing.

This is an **eMMC** backup. It does not include SPI flash or authenticated RPMB contents. Do not overwrite SPI firmware or RPMB as part of this conversion. Factory images can contain probe credentials and personal data: keep them private.

The RAM rescue generates a new SSH host key on each boot. If you reboot it, remove only the old `[probe-IP]:2222` known-hosts entry with `ssh-keygen -R '[192.168.1.78]:2222'`, then compare the new UART fingerprint again. Do not globally disable SSH host-key checking.

## 8. Install the root filesystem

This step erases **the selected partition's existing contents**. Proceed after verifying and saving the backup. Keep stable power and the UART connected.

**Rescue**, HTTP transfer:

```bash
curl --fail --retry 3 http://192.168.1.12:8000/atlas-v5-debian13-rootfs.ext4.zst -o /tmp/rootfs.ext4.zst
sha256sum /tmp/rootfs.ext4.zst
cat /etc/atlas-rootfs.sha256
zstd -t /tmp/rootfs.ext4.zst
```

The two SHA256 values must match. Alternatively, with the same file hosted on TFTP, **rescue**:

```bash
tftp -g -r atlas-v5-debian13-rootfs.ext4.zst -l /tmp/rootfs.ext4.zst 192.168.1.12
```

Some TFTP implementations have trouble with block-number rollover on larger transfers; HTTP avoids that issue. The installer also verifies the paired rootfs hash and zstd integrity, so an incomplete or wrong download cannot proceed.

After confirming your target is the existing, unmounted eMMC user partition, **rescue**:

```bash
atlas-install-rootfs /dev/mmcblk0p1 /tmp/rootfs.ext4.zst
```

Read the displayed target. Type **`ERASE /dev/mmcblk0p1`** only if that is the correct partition. The helper rejects whole disks, boot devices, mounted partitions, active swap, holders, read-only targets, and partitions smaller than 1 GiB. It decompresses the 1 GiB filesystem into the partition, runs e2fsck, then expands it with resize2fs. It preserves the partition table and eMMC boot areas.

Expected final output includes label `ATLASROOT`, ext4 type, and a filesystem UUID. The UUID is generated during the build and already matches `/etc/fstab` inside the image. Do not substitute a UUID from somebody else's build.

`e2fsck` may report “FILE SYSTEM WAS MODIFIED”; successful corrections and a successful resize are expected. If the installer reports an error, keep the rescue running and investigate before rebooting.

**Rescue:**

```bash
sync
reboot -f
```

Interrupt autoboot again. The next section performs a trial boot before saving any environment changes.

## 9. Trial boot and first login

**U-Boot:**

```text
wdt dev watchdog-timer@8300
wdt stop && echo Watchdog stopped
setenv kernel_addr_r 0x06000000
setenv fdt_addr_r 0x05f00000
mmc dev 0 0
ext4load mmc 0:1 ${kernel_addr_r} /boot/Image
ext4load mmc 0:1 ${fdt_addr_r} /boot/armada-3720-atlas-v5.dtb
setenv bootargs 'console=ttyMV0,115200n8 root=/dev/mmcblk0p1 rootfstype=ext4 rootwait ro'
booti ${kernel_addr_r} - ${fdt_addr_r}
```

No rescue ramdisk is used for installed Debian. Its eMMC and ext4 drivers are built in. Keep the kernel and DTB paired. The U-Boot data cache can remain enabled for these eMMC reads; the observed cache workaround concerns TFTP.

The tested factory partition table had a zero MBR disk signature. U-Boot reported `00000000-01`, while Linux blkid did not expose a usable PARTUUID. This guide therefore uses the observed **`root=/dev/mmcblk0p1`**, rather than assuming PARTUUID works. If your storage enumeration differs, use your verified root partition or a valid kernel-supported identifier.

At the serial login prompt, enter:

```text
login: atlas
Password: Ch@nge!Me(26)
```

Password typing is not echoed. You will be told the password has expired. Enter the same initial password when asked for the current password, then choose and confirm a strong **new** password. The session may return to the login prompt after changing it; log in again with your new password.

SSH is intentionally unavailable before this step. After the change, the shadow-file watcher starts Dropbear. The new password is used for both normal SSH login and sudo. The shared password is no longer valid. On subsequent boots, no further forced change is required unless you expire the password yourself.

**Debian, via UART:**

```bash
uname -r
ip -br addr
findmnt /
df -h /
free -h
sudo swapon --show
cat /sys/block/zram0/comp_algorithm
sudo systemctl --failed
sudo systemctl is-active dropbear systemd-networkd systemd-timesyncd systemd-zram-setup@zram0
getent ahostsv4 deb.debian.org
sudo apt-get update
sudo journalctl -u systemd-timesyncd -b --no-pager
```

Expect ext4 mounted from the installed partition, several GiB available after resize, active zram with `[lz4]`, and no failed required services. Ethernet may be named `end0` rather than `eth0`; the networkd match uses interface type and supports either.

Find the probe IP from `ip -br addr` or your router, then **PC**:

```bash
ssh atlas@192.168.1.78
```

Compare the new installed SSH host key with the probe console. To display its Ed25519 public-key fingerprint on **Debian**:

```bash
sudo dropbearkey -y -f /etc/dropbear/dropbear_ed25519_host_key
```

Host keys are generated independently on each installed probe. Do not compare this fingerprint with the RAM rescue's fingerprint; those are different systems and ports.

For SSH keys, paste a **public** key into `/home/atlas/.ssh/authorized_keys`, owned by atlas, directory mode 700 and file mode 600. Test a second SSH session with the key before disabling password authentication. To disable SSH passwords, add `-s` to Dropbear's `ExecStart` in `/etc/systemd/system/dropbear.service`, then run `sudo systemctl daemon-reload` and `sudo systemctl restart dropbear`. Your console password and sudo continue to work.

## 10. Make Debian boot automatically

Only do this after a successful trial boot and a verified backup. Saving U-Boot environment is a separate persistent change from installing the partition.

The published CZ.NIC Atlas U-Boot configuration uses a 64 KiB MMC environment at offset `0x180000` in hardware partition 2, corresponding to Linux **`/dev/mmcblk0boot1`**. See the [vendor Atlas configuration](https://gitlab.nic.cz/turris/u-boot/-/blob/ripe-atlas-2021-12-02/configs/turris_mox_defconfig). The tested firmware is a dirty vendor build, so confirm behavior on your firmware rather than assuming the published source exactly matches every binary.

`saveenv` may therefore change **boot1**. The partition installer preserves boot areas; saving the environment later does not preserve boot1 byte-for-byte. Back it up first. Do not enable `force_ro` writes or use Linux `fw_setenv` with guessed offsets.

**Debian:** `sudo reboot`, then interrupt U-Boot. **U-Boot:**

```text
setenv kernel_addr_r 0x06000000
setenv fdt_addr_r 0x05f00000
setenv atlas_boot 'wdt dev watchdog-timer@8300 && wdt stop && mmc dev 0 0 && ext4load mmc 0:1 ${kernel_addr_r} /boot/Image && ext4load mmc 0:1 ${fdt_addr_r} /boot/armada-3720-atlas-v5.dtb && setenv bootargs console=ttyMV0,115200n8 root=/dev/mmcblk0p1 rootfstype=ext4 rootwait ro && booti ${kernel_addr_r} - ${fdt_addr_r}'
setenv bootcmd 'run atlas_boot'
printenv atlas_boot bootcmd kernel_addr_r fdt_addr_r
saveenv
reset
```

Check that `saveenv` explicitly succeeds. If it fails, stop and retain manual boot rather than attempting to rewrite boot firmware. On reboot, verify automatic Debian boot and that the watchdog is stopped. The command chain stops if loading the kernel/DTB fails.

Factory logs may show “bad CRC, using default environment” before any environment has been saved. That was observed on the tested board and is not itself an instruction to overwrite firmware.

## 11. Maintenance and further size reductions

**Debian:**

```bash
sudo apt-get update
sudo apt-get upgrade
sudo apt-get clean
sudo journalctl --disk-usage
ps -eo pid,comm,rss --sort=-rss | head
df -h /
free -h
```

Install applications with `sudo apt-get install --no-install-recommends PACKAGE`. Avoid a desktop, NetworkManager, container engine, large language runtimes, and extra daemons unless the workload needs them. Keep the zram swap; it is useful with 512 MiB RAM and avoids eMMC swap writes. Journals are already volatile and bounded; rebooting discards them.

Further reduce size by removing optional packages your application does not need, optional networking modules, or QEMU-only drivers **in the source recipe**, then rebuilding and validating. Dropping QEMU drivers also removes this automated boot test, so provide another meaningful test. Avoid removing networking, sudo, certificates, time synchronization, random-number support, or security protections just to save a small amount of memory.

Public DNS is a size-saving choice, not a requirement. For a LAN resolver, edit `/etc/resolv.conf` with `sudo`. For local time display, link `/etc/localtime` to the desired zoneinfo file; UTC is the default. In this minimal image some optional administrative commands are absent until their packages are installed.

The custom kernel is **not automatically updated by Debian's stock kernel packages**. Mainline Atlas DT support was introduced after Debian 13's stock 6.12 kernel line. Track the chosen Linux LTS series, rebuild the project with its new version/hash, and test the new image/kernel before deploying. Keep the previous kernel/DTB and a matching rescue bundle for recovery.

For an in-place kernel update, transfer the newly built `.deb`, verify its SHA256, then install with `sudo dpkg -i linux-image-atlas-v5_..._arm64.deb`. Its postinst updates `/boot/Image` and the DTB symlink. Ensure `/boot` has space and have UART/rescue ready before rebooting. The provided kernel package has no header package for compiling third-party modules on the probe.

## 12. Troubleshooting and recovery

| Symptom | Action |
|---|---|
| No UART output | Check pin identification, 1.8 V logic, crossed TX/RX, shared ground, USB power, terminal baud, and no flow control. |
| `mvneta ... bad rx status ... buffer oversize`, followed by TFTP timeouts | Reset, interrupt boot, stop watchdog, run `dcache off` **before DHCP**, and use blocksize 512/window 1. A successful small DTB transfer does not prove a large transfer will work. |
| Only `T T T` during TFTP | Check firewall, TFTP root, exact filename and permissions. Reset the probe after the receive error; just retrying can leave the driver in a bad state. |
| Failed reservation of `tee@4400000` | Reload at the corrected kernel/DTB addresses; do not use `0x05000000`/`0x04f00000`. |
| Reset roughly 60 seconds after boot | The U-Boot watchdog was probably left active; stop it on every boot and include the stop in `bootcmd`. |
| `ilsblk: command not found` | The command is `lsblk`, lowercase L, not `ilsblk`. |
| `PARTUUID` is empty | A zero MBR disk signature can cause this; use the verified `/dev/mmcblk0p1` root argument. |
| Installer rejects SHA256 | Use the rescue and rootfs from the same build; redownload and verify. Do not bypass the check. |
| Cannot SSH into rescue | Use root and port 2222; add your public key through UART and verify the current RAM host key. No password login is provided. |
| Cannot SSH into new Debian | Complete the mandatory first console password change, check DHCP, then `sudo systemctl status dropbear`. Port 22 and user atlas are for installed Debian. |
| `systemctl` fails for a non-root user | Use `sudo systemctl`; this minimal image omits D-Bus/logind. |
| `swapon: command not found` as atlas | Use `sudo swapon --show` so the administrative PATH includes its directory. |
| Kernel says it cannot execute `/init`, then Debian starts | No installed initramfs is used; the kernel can fall back to the normal init. Confirm the actual root and service state. |
| Duplicate XOR debugfs name or unused optional autofs warning | These were seen during successful boots; check required services and storage rather than treating every warning as a boot failure. |

### Return to the RAM rescue

Interrupt U-Boot and repeat section 6 with a known-good, matching set of files. This boot path does not rely on the installed rootfs or persistent `bootcmd`. Inspect the partition, repair it while unmounted if appropriate, or rerun the guarded installer after backing up anything you want to retain. Reinstalling the image resets the atlas password to the shared expired default and removes installed user data.

### Restore the factory user-area backup

Restoration is different from installing the Debian filesystem: a verified `mmcblk0.img` is a **whole user-disk backup including its partition table**, and belongs on the corresponding whole user disk. The rootfs image belongs only on a partition. Confusing these destroys the layout.

Boot RAM rescue, verify that eMMC is unmounted, check the backup manifest on the PC, and confirm that the saved whole-disk file size exactly matches `blockdev --getsize64 /dev/mmcblk0`. For the tested board that was `3909091328` bytes. Serve the verified backup privately on the LAN; do not expose it publicly.

For restoration with limited RAM, stream the uncompressed backup from HTTP straight to the user disk. **Rescue**, only after independently verifying the exact image/target and accepting the overwrite:

```bash
set -o pipefail
curl --fail http://192.168.1.12:8000/mmcblk0.img | dd of=/dev/mmcblk0 bs=4M conv=fsync status=progress
sync
sha256sum /dev/mmcblk0
```

The last SHA256 must equal the saved `mmcblk0.img` checksum. If transfer or hash verification fails, remain in rescue and repair/retry; do not treat a partially restored disk as bootable. This manual recovery command is deliberately different from the partition-only installer.

If you changed only the user partition and did not save a new environment, the untouched boot0/boot1 and SPI firmware normally do not need restoration. If you saved a Debian `bootcmd`, restoring the user disk alone leaves that environment pointing at Debian paths. Restore your saved factory `printenv` values in U-Boot and save the environment only after confirming the correct factory boot settings. Preserve the boot-area backups for firmware-specific recovery; do not blindly write boot0/boot1 or SPI flash.

## 13. Design references and validation

Board support and boot interfaces are based on the [OpenWrt Atlas support commit](https://github.com/openwrt/openwrt/commit/42b10de18d65963cc83dca5ee3d58f01836a7221), the [Linux board-support commit](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=0b738a2901f43980fc2307a50a26457be1c8030b) and [related Linux commit](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=d1a7bf9031b9f91b86187bcd5bd7a4bfd76bcaef), and [U-Boot booti documentation](https://docs.u-boot.org/en/latest/usage/cmd/booti.html). The first-login account expiry uses [Debian chage](https://manpages.debian.org/trixie/passwd/chage.1.en.html). Filesystem expansion follows [resize2fs](https://manpages.debian.org/trixie/e2fsprogs/resize2fs.8.en.html).

The underlying 6.18.54 Atlas kernel, UART, corrected RAM load addresses, TFTP cache workaround, eMMC partition installation/resize, installed Debian boot, Ethernet, SSH, and LZ4 zram were verified on one physical v5 board with 512 MiB RAM. Its firmware reported CZ.NIC Secure Firmware v2021.09.07-24-gb26fb81-dirty, TF-A 2.6, and U-Boot 2022.01-rc3-01583-gb23129dad2-dirty.

The public `atlas` account/password change, clean image identities, and matching public rescue are validated by the automated QEMU checks included with each successful build. The physical board was previously running a personal build; do not interpret its earlier validation as a physical reflash test of every later public image. Automatic boot after `saveenv` still requires verification on your own firmware. Check `dist/qa-image.txt`, `dist/qa-rescue.txt`, `dist/memory-layout.txt`, and `dist/build-info.txt` for each release.

The TFTP cache workaround is an observed fix on the tested vendor U-Boot, not proof of the exact underlying driver defect. Other firmware versions may behave differently. Keep UART, factory backups, and a known-good rescue available until your own installation and reboot tests pass.
