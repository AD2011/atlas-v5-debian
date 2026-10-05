#!/bin/bash
# Run in a disposable ARM64 Debian container with /work/input and /work/out.
set -euo pipefail
stage=/work/rescue
rm -rf -- "$stage"
mkdir -p "$stage"/{bin,sbin,usr/bin,usr/sbin,dev,etc,proc,sys,run,tmp,mnt,root/.ssh}
cp /bin/busybox "$stage/bin/"
while read -r applet; do
    test "$applet" = busybox || ln -s /bin/busybox "$stage/bin/$applet"
done < <(/bin/busybox --list)
export RESCUE_STAGE="$stage"
python3 - <<'PY'
import os, pathlib, shutil, subprocess, re
stage = pathlib.Path(os.environ['RESCUE_STAGE'])
commands = ['bash', 'dd', 'sha256sum', 'stat', 'curl', 'zstd', 'e2fsck',
            'resize2fs', 'blkid', 'blockdev', 'lsblk', 'sfdisk', 'findmnt',
            'dropbear', 'dropbearkey']
def copy(source, target=None):
    src = pathlib.Path(source)
    dst = stage / (target or str(src)).lstrip('/')
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink():
        dst.unlink()
    shutil.copyfile(src, dst)
    dst.chmod(src.stat().st_mode & 0o777)
for name in commands:
    source = shutil.which(name)
    if not source:
        raise RuntimeError('Missing binary: ' + name)
    target = ('/bin/' if name in ['bash', 'dd', 'sha256sum', 'stat'] else '/usr/bin/') + name
    copy(source, target)
    result = subprocess.run(['ldd', source], text=True, capture_output=True, check=True)
    for line in result.stdout.splitlines():
        match = re.search(r'(?:=>\s+)?(/\S+)', line)
        if match:
            copy(match.group(1))
PY
install -m 755 /work/input/scripts/rescue-init.sh "$stage/init"
install -m 755 /work/input/scripts/atlas-install-rootfs.sh "$stage/usr/bin/atlas-install-rootfs"
install -m 600 /work/input/authorized_keys "$stage/root/.ssh/authorized_keys"
chmod 700 "$stage/root/.ssh"
sha256sum /work/out/atlas-v5-debian13-rootfs.ext4.zst | cut -d ' ' -f 1 > "$stage/etc/atlas-rootfs.sha256"
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$stage/etc/passwd"
printf '/bin/sh\n/bin/bash\n' > "$stage/etc/shells"
printf 'root:*:20000:0:99999:7:::\n' > "$stage/etc/shadow"
chmod 600 "$stage/etc/shadow"
printf 'root:x:0:\n' > "$stage/etc/group"
printf '127.0.0.1 localhost atlas-rescue\n' > "$stage/etc/hosts"
printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' > "$stage/etc/nsswitch.conf"
cat > "$stage/etc/udhcpc.script" <<'EOF'
#!/bin/busybox sh
case "$1" in
    deconfig) ip addr flush dev "$interface" ;;
    bound|renew)
        ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
        ip route del default dev "$interface" 2>/dev/null || true
        for gateway in $router; do ip route add default via "$gateway" dev "$interface"; break; done
        : > /etc/resolv.conf
        for server in $dns; do echo "nameserver $server" >> /etc/resolv.conf; done
        ip addr show dev "$interface"
        ;;
esac
EOF
chmod 755 "$stage/etc/udhcpc.script"
mknod -m 600 "$stage/dev/console" c 5 1
mknod -m 666 "$stage/dev/null" c 1 3
cp /etc/e2fsck.conf "$stage/etc/" 2>/dev/null || true
(cd "$stage"; find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --owner=0:0 | gzip -6 > /work/out/atlas-v5-rescue.cpio.gz)
dpkg-query -W -f='${binary:Package}\t${Version}\n' > /work/out/rescue-builder-packages.tsv
du -sb "$stage" > /work/out/rescue-uncompressed-size.txt
cat > /work/out/rescue-build-info.txt <<EOF
Build UTC: $(date -u --iso-8601=seconds)
Builder digest: ${BUILDER_IMAGE_DIGEST:-unknown}
Architecture: arm64
Kernel: supplied Image, Linux 6.18.54-atlas-v5
Rootfs SHA256: $(cat "$stage/etc/atlas-rootfs.sha256")
Rescue: RAM-only BusyBox / bash, DHCP IPv4, SSH root public-key login on port 2222
Automatic storage mounts or writes: none
SSH host keys: generated in RAM each boot; no private key in artifact
EOF
for cmd in bash curl zstd e2fsck resize2fs blkid blockdev lsblk sfdisk findmnt dropbear dropbearkey; do
    chroot "$stage" /bin/sh -c "command -v $cmd" >/dev/null
done
