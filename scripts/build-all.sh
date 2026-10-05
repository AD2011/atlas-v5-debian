#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 TMPDIR=/work/tmp
mkdir -p "$TMPDIR" /work/out
exec > >(tee /work/build.log) 2>&1
trap 'status=$?; cp /work/build.log /work/out/build.log; chown -R "${HOST_UID:-0}:${HOST_GID:-0}" /work; exit "$status"' EXIT
source /work/input/build.env
export KERNEL_VERSION KERNEL_SHA256
apt-get update
apt-get install -y --no-install-recommends \
    mmdebstrap ca-certificates curl xz-utils zstd build-essential bc bison flex \
    libssl-dev libelf-dev kmod cpio python3 python3-pexpect python3-paramiko \
    e2fsprogs device-tree-compiler qemu-system-arm qemu-utils openssl \
    debian-archive-keyring busybox-static bash coreutils util-linux fdisk dropbear-bin gzip
bash /work/input/scripts/build-image.sh
python3 /work/input/tools/qa_image.py
zstd -f -T2 -6 /work/out/atlas-v5-debian13-rootfs.ext4 -o /work/out/atlas-v5-debian13-rootfs.ext4.zst
rm /work/out/atlas-v5-debian13-rootfs.ext4
bash /work/input/scripts/build-rescue.sh
python3 /work/input/tools/qa_rescue.py
python3 /work/input/tools/package.py
