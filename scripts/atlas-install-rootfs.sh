#!/bin/bash
# Explicitly invoked installer; the rescue system never runs this on boot.
set -euo pipefail
die() { echo "STOP: $*" >&2; exit 1; }
test "$#" = 2 || die 'Usage: atlas-install-rootfs /dev/mmcblkNpN downloaded-image.ext4.zst'
device=$1
image=$2
[[ "$device" =~ ^/dev/mmcblk[0-9]+p[0-9]+$ ]] || die 'Select an eMMC user-area partition, not a whole disk or boot0/boot1.'
test -b "$device" || die 'Target partition does not exist.'
test -f "$image" || die 'Compressed image does not exist.'
name=${device##*/}
test -f "/sys/class/block/$name/partition" || die 'Target is not a real partition.'
parent=$(basename "$(dirname "$(readlink -f "/sys/class/block/$name")")")
[[ "$parent" =~ ^mmcblk[0-9]+$ ]] || die 'Target is not on the eMMC user area.'
test "$(cat "/sys/class/block/$parent/device/type")" = MMC || die 'Target is not an MMC device.'
test "$(blockdev --getro "$device")" = 0 || die 'Target is read-only.'
test "$(blockdev --getsize64 "$device")" -ge 1073741824 || die 'Target must be at least 1 GiB.'
devno=$(lsblk -dnro MAJ:MIN "$device")
if awk -v n="$devno" '$3 == n {found=1} END {exit !found}' /proc/self/mountinfo; then
    die 'Target is mounted. Unmount it before installation.'
fi
if awk -v d="$device" '$1 == d {found=1} END {exit !found}' /proc/swaps; then
    die 'Target is active swap.'
fi
if compgen -G "/sys/class/block/$name/holders/*" >/dev/null; then
    die 'Another block device is using the target.'
fi
expected=$(cat /etc/atlas-rootfs.sha256)
actual=$(sha256sum "$image")
test "${actual%% *}" = "$expected" || die 'Image SHA256 does not match this rescue bundle.'
zstd -t -- "$image"
echo 'Target (all existing contents on this partition will be overwritten):'
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS "$device"
echo 'The partition table and the eMMC boot devices will be preserved.'
echo 'Continue only after saving and verifying the complete eMMC backup on your PC.'
read -r -p "Type ERASE $device to proceed: " reply
test "$reply" = "ERASE $device" || die 'Confirmation did not match.'
zstd -dc -- "$image" | dd of="$device" bs=4M conv=fsync status=progress
sync
set +e
e2fsck -f "$device"
result=$?
set -e
test "$result" -le 1 || die "Filesystem check returned $result; do not continue."
resize2fs "$device"
sync
blkid "$device"
echo 'Root filesystem installed. Follow README.md for a trial boot.'
