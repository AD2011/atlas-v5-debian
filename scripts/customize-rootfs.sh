#!/bin/bash
set -euo pipefail
R=/work/rootfs
install -d "$R/etc/systemd/network" "$R/etc/systemd/journald.conf.d" \
    "$R/etc/systemd/system" "$R/etc/dropbear" "$R/usr/local/sbin" "$R/home/atlas/.ssh"
printf 'atlas-v5\n' > "$R/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 atlas-v5\n::1 localhost ip6-localhost ip6-loopback\n' > "$R/etc/hosts"
printf 'nameserver 1.1.1.1\nnameserver 9.9.9.9\n' > "$R/etc/resolv.conf"
printf 'UUID=%s / ext4 defaults,noatime 0 1\n' "$ROOT_UUID" > "$R/etc/fstab"
cat > "$R/etc/systemd/network/20-ethernet.network" <<'EOF'
[Match]
Type=ether
[Network]
DHCP=yes
IPv6AcceptRA=yes
[DHCPv4]
UseDNS=no
[DHCPv6]
UseDNS=no
EOF
cat > "$R/etc/systemd/journald.conf.d/10-small.conf" <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=8M
RuntimeMaxFileSize=1M
ForwardToSyslog=no
EOF
cat > "$R/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
EOF
install -m 755 /work/input/scripts/password-changed.sh "$R/usr/local/sbin/atlas-password-changed"
cat > "$R/etc/systemd/system/dropbear.service" <<'EOF'
[Unit]
Description=Dropbear SSH server (after initial console password change)
After=network.target
[Service]
ExecCondition=/usr/local/sbin/atlas-password-changed
ExecStart=/usr/sbin/dropbear -F -E -R -w -p 22
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
cat > "$R/etc/systemd/system/atlas-ssh-unlock.service" <<'EOF'
[Unit]
Description=Start SSH after the initial console password change
After=network.target
[Service]
Type=oneshot
ExecCondition=/usr/local/sbin/atlas-password-changed
ExecStart=/bin/systemctl start dropbear.service
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
cat > "$R/etc/systemd/system/atlas-ssh-unlock.path" <<'EOF'
[Unit]
Description=Watch for the initial console password change
[Path]
PathChanged=/etc/shadow
Unit=atlas-ssh-unlock.service
[Install]
WantedBy=multi-user.target
EOF
chroot "$R" useradd --create-home --uid 1000 --shell /bin/bash --groups sudo atlas
printf '%s\n' 'atlas:Ch@nge!Me(26)' | chroot "$R" chpasswd
chroot "$R" chage -d 0 atlas
chroot "$R" passwd -l root
install -m 600 /work/input/authorized_keys "$R/home/atlas/.ssh/authorized_keys"
chown -R 1000:1000 "$R/home/atlas"
chmod 700 "$R/home/atlas/.ssh"
# Debian's normal sudo group rule requires the user's password.
chroot "$R" visudo -c
chroot "$R" systemctl enable dropbear.service atlas-ssh-unlock.path atlas-ssh-unlock.service \
    systemd-networkd.service systemd-timesyncd.service
chroot "$R" systemctl mask systemd-logind.service
chroot "$R" systemctl set-default multi-user.target
ln -sfn "Image-$KERNEL_RELEASE" "$R/boot/Image"
ln -sfn "dtbs/$KERNEL_RELEASE/marvell/armada-3720-atlas-v5.dtb" "$R/boot/armada-3720-atlas-v5.dtb"
cat > "$R/etc/issue" <<'EOF'
Debian 13 on RIPE Atlas v5
First console login: atlas / Ch@nge!Me(26)
You MUST choose a new password. SSH starts only after this change.

EOF
cat > "$R/etc/motd" <<'EOF'
RIPE Atlas v5 - minimal Debian 13
Change the shared initial password on first console login. Never keep it.
Use sudo for administrative commands. Root login is disabled.
SSH starts after the initial password change; use your new password or SSH key.
EOF
printf 'LANG=C.UTF-8\n' > "$R/etc/default/locale"
ln -sfn /usr/share/zoneinfo/Etc/UTC "$R/etc/localtime"
: > "$R/etc/machine-id"
rm -f "$R/var/lib/dbus/machine-id" "$R/var/lib/systemd/random-seed"
find "$R/etc/dropbear" -maxdepth 1 -type f -name '*host_key' -delete
find "$R/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -delete 2>/dev/null || true
chroot "$R" apt-get clean
find "$R/var/lib/apt/lists" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
find "$R/var/log" -type f -exec truncate -s 0 {} +
rm -f "$R/usr/sbin/policy-rc.d"
find "$R/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
