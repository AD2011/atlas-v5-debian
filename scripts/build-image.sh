#!/bin/bash
set -euo pipefail
export TMPDIR=/work/tmp
mkdir -p "$TMPDIR" /work/out /work/kernel
SOURCE_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
echo "STAGE: download and verify Linux ${KERNEL_VERSION} LTS"
if ! test -f /work/linux.tar.xz; then
    curl --fail --location --retry 3 "$SOURCE_URL" -o /work/linux.tar.xz
fi
printf '%s  linux.tar.xz\n' "$KERNEL_SHA256" > /work/source.sha256
(cd /work; sha256sum -c source.sha256)
mkdir -p /work/linux
if ! test -f /work/linux/Makefile; then
    tar -xJf /work/linux.tar.xz --strip-components=1 -C /work/linux
fi
test -f /work/linux/arch/arm64/boot/dts/marvell/armada-3720-atlas-v5.dts

echo 'STAGE: configure minimal Armada 3720 kernel'
bash /work/input/scripts/kernel-config.sh
echo 'STAGE: compile kernel, Atlas device tree and optional network/zram modules'
export KBUILD_BUILD_USER=atlas KBUILD_BUILD_HOST=isolated-arm64-builder
export KBUILD_BUILD_TIMESTAMP="$(date -u '+%a %b %d %T UTC %Y')"
make -C /work/linux ARCH=arm64 O=/work/kernel -j"${JOBS:-3}" \
    Image marvell/armada-3720-atlas-v5.dtb modules
KERNEL_RELEASE=$(make -s -C /work/linux ARCH=arm64 O=/work/kernel kernelrelease)
printf '%s\n' "$KERNEL_RELEASE" > /work/out/kernel-release.txt

echo 'STAGE: package custom kernel for dpkg ownership and future replacement'
KPKG=/work/kernel-package
rm -rf -- "$KPKG"
mkdir -p "$KPKG/boot/dtbs/$KERNEL_RELEASE/marvell" "$KPKG/DEBIAN" "$KPKG/usr/share/doc/linux-image-atlas-v5"
install -m 644 /work/kernel/arch/arm64/boot/Image "$KPKG/boot/Image-$KERNEL_RELEASE"
install -m 644 /work/kernel/arch/arm64/boot/dts/marvell/armada-3720-atlas-v5.dtb \
    "$KPKG/boot/dtbs/$KERNEL_RELEASE/marvell/armada-3720-atlas-v5.dtb"
install -m 644 /work/kernel/.config "$KPKG/boot/config-$KERNEL_RELEASE"
make -C /work/linux ARCH=arm64 O=/work/kernel INSTALL_MOD_PATH="$KPKG" INSTALL_MOD_STRIP=1 modules_install
rm -f "$KPKG/lib/modules/$KERNEL_RELEASE/build" "$KPKG/lib/modules/$KERNEL_RELEASE/source"
find "$KPKG" -name '*.ko' -exec xz -T1 -f {} +
depmod -b "$KPKG" "$KERNEL_RELEASE"
cat > "$KPKG/DEBIAN/control" <<EOF
Package: linux-image-atlas-v5
Version: ${KERNEL_VERSION}-1
Architecture: arm64
Maintainer: Atlas local build <atlas@localhost>
Section: kernel
Priority: optional
Depends: kmod
Description: Minimal Linux LTS kernel for RIPE Atlas Probe v5
 Built-in eMMC, ext4, Ethernet, UART and Armada 3720 support.
 Includes small virtio and PL011 drivers for QEMU boot verification.
EOF
cat /work/linux/COPYING /work/linux/LICENSES/preferred/GPL-2.0 > "$KPKG/usr/share/doc/linux-image-atlas-v5/copyright"
cat > "$KPKG/DEBIAN/postinst" <<EOF
#!/bin/sh
set -eu
if [ "\$1" = configure ]; then
    depmod "$KERNEL_RELEASE"
    ln -sfn "Image-$KERNEL_RELEASE" /boot/Image
    ln -sfn "dtbs/$KERNEL_RELEASE/marvell/armada-3720-atlas-v5.dtb" /boot/armada-3720-atlas-v5.dtb
fi
EOF
chmod 755 "$KPKG/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$KPKG" "/work/out/linux-image-atlas-v5_${KERNEL_VERSION}-1_arm64.deb"

echo 'STAGE: create Debian 13 ARM64 minbase root filesystem'
cat > /work/debian.sources.list <<'EOF'
deb https://deb.debian.org/debian trixie main
deb https://deb.debian.org/debian trixie-updates main
deb https://security.debian.org/debian-security trixie-security main
EOF
if ! test -f /work/rootfs/var/lib/dpkg/status; then
mmdebstrap --mode=unshare --architectures=arm64 --variant=minbase \
    --include=systemd-sysv,udev,dropbear,sudo,iproute2,procps,ca-certificates,systemd-timesyncd,kmod,e2fsprogs,systemd-zram-generator \
    --aptopt='APT::Install-Recommends "false"' \
    --aptopt='APT::Install-Suggests "false"' \
    --aptopt='Acquire::Languages "none"' \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/info/*' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    --dpkgopt='path-exclude=/usr/share/locale/*' \
    --dpkgopt='path-include=/usr/share/locale/locale.alias' \
    trixie /work/rootfs /work/debian.sources.list
fi

cp "/work/out/linux-image-atlas-v5_${KERNEL_VERSION}-1_arm64.deb" /work/rootfs/tmp/kernel.deb
chroot /work/rootfs dpkg -i /tmp/kernel.deb
rm /work/rootfs/tmp/kernel.deb
if test -f /work/out/rootfs-uuid.txt; then
    ROOT_UUID=$(cat /work/out/rootfs-uuid.txt)
else
    ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)
fi
printf '%s\n' "$ROOT_UUID" > /work/out/rootfs-uuid.txt
export KERNEL_RELEASE ROOT_UUID
bash /work/input/scripts/customize-rootfs.sh

echo 'STAGE: validate package state, board configuration and service units'
bash /work/input/scripts/verify-rootfs.sh | tee /work/out/verification.txt
chroot /work/rootfs dpkg-query -W -f='${binary:Package}\t${Version}\t${Installed-Size}\n' \
    > /work/out/packages.tsv
cp /work/kernel/.config /work/out/kernel.config
cp /work/linux/arch/arm64/boot/dts/marvell/armada-3720-atlas-v5.dts /work/out/atlas-v5.dts
cp "$KPKG/boot/Image-$KERNEL_RELEASE" /work/out/Image
cp "$KPKG/boot/dtbs/$KERNEL_RELEASE/marvell/armada-3720-atlas-v5.dtb" /work/out/armada-3720-atlas-v5.dtb
cp /work/source.sha256 /work/out/kernel-source.sha256
cp /work/debian.sources.list /work/out/debian.sources.list
du -sx --block-size=1 /work/rootfs | awk '{print $1}' > /work/out/rootfs-installed-bytes.txt
cat > /work/out/build-info.txt <<EOF
Build date UTC: $(date -u --iso-8601=seconds)
Distribution: Debian 13 (trixie), arm64, minbase
Kernel: $KERNEL_RELEASE
Kernel source: $SOURCE_URL
Builder image digest: ${BUILDER_IMAGE_DIGEST:-unknown}
Compiler: $(gcc -dumpfullversion)
Root filesystem UUID: $ROOT_UUID
Root filesystem image capacity: 1073741824 bytes (1 GiB), expandable
No initramfs required: eMMC and ext4 are built into the kernel
User: atlas (sudo requires password)
Root password: locked
Initial password: Ch@nge!Me(26), expires on first console login
SSH: disabled until initial password is changed, then passwords/keys accepted
SSH host keys: generated on the target, absent from pristine image
EOF

echo 'STAGE: create filesystem image and compressed rootfs archive'
truncate -s 1G /work/out/atlas-v5-debian13-rootfs.ext4
mkfs.ext4 -q -F -L ATLASROOT -U "$ROOT_UUID" -m 1 \
    -O '^64bit,^metadata_csum_seed,^orphan_file' -d /work/rootfs \
    /work/out/atlas-v5-debian13-rootfs.ext4
e2fsck -f -n /work/out/atlas-v5-debian13-rootfs.ext4
tar --numeric-owner --xattrs --acls -C /work/rootfs -cpf - . \
    | zstd -f -T2 -6 -o /work/out/atlas-v5-debian13-rootfs.tar.zst

