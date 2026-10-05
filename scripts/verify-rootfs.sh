#!/bin/bash
set -euo pipefail
R=/work/rootfs
test "$(chroot "$R" dpkg --print-architecture)" = arm64
test -z "$(chroot "$R" dpkg --audit)"
test ! -s "$R/etc/machine-id"
test ! -e "$R/var/lib/systemd/random-seed"
test -z "$(find "$R/etc/dropbear" -name '*host_key' -print)"
test "$(chroot "$R" id -u atlas)" = 1000
test "$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' "$R/etc/passwd")" = atlas
python3 - <<'PY'
import ctypes, pathlib
lib = ctypes.CDLL("libcrypt.so.1")
lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
lib.crypt.restype = ctypes.c_char_p
users = {s.split(':')[0]: s.split(':') for s in pathlib.Path('/work/rootfs/etc/shadow').read_text().splitlines()}
atlas = users['atlas']
assert atlas[2] == '0', 'Initial password must be expired'
assert lib.crypt(b'Ch@nge!Me(26)', atlas[1].encode()).decode() == atlas[1], 'Unexpected initial password'
assert users['root'][1].startswith(('!', '*')), 'Root must be locked'
PY
cmp /work/input/authorized_keys "$R/home/atlas/.ssh/authorized_keys"
test "$(stat -c '%u:%g:%a' "$R/home/atlas/.ssh/authorized_keys")" = 1000:1000:600
chroot "$R" visudo -c
test -s "$R/boot/Image-$KERNEL_RELEASE"
test "$(fdtget /work/kernel/arch/arm64/boot/dts/marvell/armada-3720-atlas-v5.dtb / model)" = 'RIPE Atlas Probe v5'
grep -qx "UUID=$ROOT_UUID / ext4 defaults,noatime 0 1" "$R/etc/fstab"
for service in dropbear.service atlas-ssh-unlock.path atlas-ssh-unlock.service systemd-networkd.service systemd-timesyncd.service; do
    chroot "$R" systemctl is-enabled "$service"
done
chroot "$R" systemd-analyze verify dropbear.service atlas-ssh-unlock.path atlas-ssh-unlock.service
for module in zram wireguard nf_tables; do modinfo -b "$R" -k "$KERNEL_RELEASE" "$module" >/dev/null; done
echo 'Pristine image account, expiry, identities, kernel, services and modules verified.'
