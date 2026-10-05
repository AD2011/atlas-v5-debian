set -euo pipefail
case "$(uname -r)" in *-atlas-v5) ;; *) exit 1 ;; esac
test "$(hostname)" = atlas-v5
test "$(id -u atlas)" = 1000
test "$(dpkg --print-architecture)" = arm64
test -z "$(dpkg --audit)"
test "$(systemctl --failed --no-legend | wc -l)" = 0
systemctl is-active dropbear systemd-networkd systemd-timesyncd systemd-zram-setup@zram0
test "$(awk '/MemTotal:/ {print $2}' /proc/meminfo)" -lt 524288
test "$(awk -F: '$1=="atlas" {print $3}' /etc/shadow)" -gt 0
grep -q '\[lz4\]' /sys/block/zram0/comp_algorithm
swapon --show
findmnt -no SOURCE,FSTYPE,OPTIONS /
ip -4 addr
ip route
getent ahostsv4 deb.debian.org >/dev/null
apt-get update
uname -a
free -h
df -h /
echo 'Guest health, package state, DHCP/DNS, signed APT, SSH and LZ4 zram passed.'
