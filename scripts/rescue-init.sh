#!/bin/busybox sh
# This initramfs never mounts or writes the probe's storage automatically.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=vt100
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /proc /sys /run /tmp /mnt
mount -t devpts devpts /dev/pts
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs -o size=128M,mode=1777 tmpfs /tmp
mount -t tmpfs -o size=16M tmpfs /run
hostname atlas-rescue
ip link set lo up

# DHCP uses the first Ethernet interface; static addressing remains available
# from the serial shell if the LAN has no DHCP server.
for path in /sys/class/net/*; do
    iface=${path##*/}
    [ "$iface" = lo ] && continue
    ip link set "$iface" up
    udhcpc -i "$iface" -s /etc/udhcpc.script -b -t 5 -T 3 -p /run/udhcpc.pid &
    break
done

mkdir -p /etc/dropbear
dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key
dropbear -E -s -p 2222 -r /etc/dropbear/dropbear_ed25519_host_key
echo
echo 'Atlas RAM rescue: no eMMC filesystem has been mounted or changed.'
echo 'SSH: root@<DHCP-IP>, port 2222, public key only. Compare the host key above.'
echo 'Use ip addr, lsblk and blkid to inspect the probe. Type reboot -f to leave.'
echo 'Do not write the rootfs image to a whole disk or to an eMMC boot device.'
echo
while :; do
    setsid sh -c 'exec bash -i </dev/console >/dev/console 2>&1'
    sleep 1
done
