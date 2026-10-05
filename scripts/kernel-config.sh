#!/bin/bash
set -euo pipefail
cd /work/linux
make ARCH=arm64 O=/work/kernel defconfig
cfg() { scripts/config --file /work/kernel/.config "$@"; }
cfg --enable EXPERT
# Start from the upstream ARM64 defconfig, preserving its core security and
# systemd support. Retain MVEBU and small QEMU virt drivers for boot validation.
while read -r symbol; do
    case "$symbol" in
        ARCH_MVEBU) ;;
        *) cfg --disable "$symbol" ;;
    esac
done < <(sed -n 's/^CONFIG_\(ARCH_[A-Z0-9_]*\)=[ym]$/\1/p' /work/kernel/.config)
while read -r symbol; do
    test "$symbol" = NET_VENDOR_MARVELL || cfg --disable "$symbol"
done < <(sed -n 's/^CONFIG_\(NET_VENDOR_[A-Z0-9_]*\)=[ym]$/\1/p' /work/kernel/.config)
while read -r symbol; do
    case "$symbol" in
        PHYLIB|PHYLINK|MARVELL_PHY|FIXED_PHY) ;;
        *) cfg --disable "$symbol" ;;
    esac
done < <(sed -n 's/^config \([A-Z0-9_]*\)$/\1/p' drivers/net/phy/Kconfig)
# ARM64 selects POWER_SUPPLY unconditionally. Keep its small core, while
# excluding battery/charger drivers that this USB-powered board does not use.
while read -r symbol; do
    test "$symbol" = POWER_SUPPLY || cfg --disable "$symbol"
done < <(sed -n 's/^config \([A-Z0-9_]*\)$/\1/p' drivers/power/supply/Kconfig)
for symbol in PCI PCIEPORTBUS ACPI EFI EFI_STUB COMPAT KVM XEN \
    USB_SUPPORT USB_GADGET USB DRM SOUND SND MEDIA_SUPPORT \
    WIRELESS WLAN CFG80211 MAC80211 BT INPUT HID VT FB \
    SCSI ATA SATA_HOST SPI I2C I3C MTD PHY_MVEBU_CP110_COMPHY \
    TYPEC POWER_SUPPLY THERMAL WATCHDOG \
    BTRFS_FS F2FS_FS XFS_FS NFS_FS NFSD CIFS FUSE_FS \
    AUTOFS_FS ISO9660_FS UDF_FS NTFS3_FS VFAT_FS \
    DEBUG_INFO DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT DEBUG_INFO_BTF \
    DEBUG_KERNEL FTRACE KPROBES PROFILING PERF_EVENTS KGDB \
    RC_CORE MEDIA_CEC_SUPPORT CAN RFKILL BACKLIGHT_CLASS_DEVICE \
    CHROME_PLATFORMS CROS_EC CROS_EC_RPMSG CROS_EC_PROTO MFD_CROS_EC_DEV \
    MVPP2 MV643XX_ETH NET_9P 9P_FS SQUASHFS JFS_FS REISERFS_FS \
    RD_BZIP2 RD_LZMA RD_XZ RD_LZO RD_LZ4 RD_ZSTD \
    ARM64_16K_PAGES ARM64_64K_PAGES; do
    cfg --disable "$symbol"
done
for symbol in ARCH_MVEBU ARM64_4K_PAGES SMP MODULES MODULE_UNLOAD \
    BLK_DEV_INITRD RD_GZIP DEVTMPFS DEVTMPFS_MOUNT \
    TMPFS TMPFS_POSIX_ACL TMPFS_XATTR \
    CGROUPS CGROUP_PIDS CGROUP_CPUACCT CGROUP_SCHED MEMCG \
    NAMESPACES UTS_NS IPC_NS USER_NS PID_NS NET_NS \
    INET IPV6 PACKET UNIX NETFILTER NETFILTER_ADVANCED \
    POSIX_TIMERS EPOLL SIGNALFD TIMERFD INOTIFY_USER FANOTIFY \
    SECCOMP SECCOMP_FILTER SECURITY SECURITYFS SECURITY_APPARMOR \
    STACKPROTECTOR STACKPROTECTOR_STRONG \
    SERIAL_MVEBU_UART SERIAL_MVEBU_CONSOLE \
    ARMADA_37XX_CLK PINCTRL_ARMADA_37XX GPIOLIB \
    REGULATOR REGULATOR_FIXED_VOLTAGE REGULATOR_GPIO \
    MMC MMC_BLOCK MMC_SDHCI MMC_SDHCI_PLTFM MMC_SDHCI_XENON \
    EXT4_FS EXT4_FS_POSIX_ACL EXT4_FS_SECURITY \
    MSDOS_PARTITION EFI_PARTITION \
    NETDEVICES NET_VENDOR_MARVELL MVNETA MVMDIO PHYLIB MARVELL_PHY \
    ARMADA_37XX_RWTM_MBOX TURRIS_MOX_RWTM HW_RANDOM \
    LEDS_CLASS LEDS_GPIO LEDS_TRIGGERS LEDS_TRIGGER_DEFAULT_ON \
    CPU_FREQ CPU_FREQ_STAT CPU_FREQ_DEFAULT_GOV_ONDEMAND \
    CPU_FREQ_GOV_PERFORMANCE CPU_FREQ_GOV_ONDEMAND CPUFREQ_DT ARM_ARMADA_37XX_CPUFREQ \
    VIRTIO VIRTIO_MMIO VIRTIO_BLK VIRTIO_NET HW_RANDOM_VIRTIO \
    ARM_AMBA SERIAL_AMBA_PL011 SERIAL_AMBA_PL011_CONSOLE \
    CRYPTO CRYPTO_AES CRYPTO_SHA256 CRYPTO_USER_API_HASH \
    CRYPTO_USER_API_SKCIPHER LZ4_COMPRESS LZ4_DECOMPRESS ZRAM_BACKEND_LZ4; do
    cfg --enable "$symbol"
done
for symbol in ZRAM NF_TABLES NFT_CT NFT_COUNTER NFT_LOG NFT_LIMIT \
    NFT_REJECT NFT_NAT NFT_MASQ NF_CONNTRACK NF_NAT TUN WIREGUARD; do
    cfg --module "$symbol"
done
cfg --set-val NR_CPUS 2
cfg --set-val HZ 250
cfg --set-val DEFAULT_MMAP_MIN_ADDR 65536
cfg --set-str LOCALVERSION '-atlas-v5'
cfg --disable LOCALVERSION_AUTO
cfg --set-str SYSTEM_TRUSTED_KEYS ''
cfg --set-str SYSTEM_REVOCATION_KEYS ''
make ARCH=arm64 O=/work/kernel olddefconfig
# Fail before compilation if any indispensable board/boot option was lost to
# a Kconfig dependency. Every root filesystem driver must be built in.
for symbol in ARCH_MVEBU SERIAL_MVEBU_UART SERIAL_MVEBU_CONSOLE \
    ARMADA_37XX_CLK PINCTRL_ARMADA_37XX REGULATOR_GPIO \
    MMC MMC_BLOCK MMC_SDHCI_XENON EXT4_FS MVNETA MVMDIO MARVELL_PHY \
    DEVTMPFS CGROUPS SECCOMP VIRTIO_BLK VIRTIO_NET SERIAL_AMBA_PL011 \
    ARM_ARMADA_37XX_CPUFREQ TURRIS_MOX_RWTM ARMADA_37XX_RWTM_MBOX; do
    grep -qx "CONFIG_${symbol}=y" /work/kernel/.config || {
        echo "Required kernel configuration missing: $symbol" >&2
        exit 1
    }
done
for symbol in PCI USB DRM SOUND VT INPUT RC_CORE CAN; do
    if grep -q "^CONFIG_${symbol}=[ym]$" /work/kernel/.config; then
        echo "Unneeded kernel subsystem remains enabled: $symbol" >&2
        exit 1
    fi
done
