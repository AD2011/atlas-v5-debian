"""Check rescue boot, paired rootfs download, installer guards and ext4 expansion."""
import pathlib
import socket
import subprocess

from qa_image import serial_connect


def main():
    out = pathlib.Path('/work/out')
    qa = pathlib.Path('/work/qa')
    target = qa / 'disposable-target.raw'
    with target.open('wb') as f:
        f.truncate(1400 * 1024 * 1024)
    sockpath = qa / 'rescue.sock'
    sockpath.unlink(missing_ok=True)
    http = subprocess.Popen(['python3', '-m', 'http.server', '8080', '--bind', '0.0.0.0',
                             '--directory', str(out)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    process = subprocess.Popen([
        'qemu-system-aarch64', '-machine', 'virt', '-cpu', 'cortex-a53', '-m', '512', '-smp', '2',
        '-accel', 'tcg,thread=multi', '-kernel', str(out / 'Image'),
        '-initrd', str(out / 'atlas-v5-rescue.cpio.gz'),
        '-append', 'console=ttyAMA0,115200n8 rdinit=/init',
        '-drive', f'if=none,id=target,file={target},format=raw', '-device', 'virtio-blk-device,drive=target',
        '-netdev', 'user,id=net0', '-device', 'virtio-net-device,netdev=net0',
        '-object', 'rng-random,id=rng0,filename=/dev/urandom', '-device', 'virtio-rng-device,rng=rng0',
        '-display', 'none', '-monitor', 'none', '-serial', f'unix:{sockpath},server=on,wait=on'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sock = None
    try:
        sock, console = serial_connect(sockpath, process)
        console.expect(r'bash-[0-9.]+#')
        (out / 'qa-rescue.txt').write_text(console.before)
        # Commands after the marker run in a disposable virtual disk, never the probe.
        command = '''sleep 5; bash -se <<'QAEOF'
test -z "$(awk '$3 ~ /^ext[234]$/ {print}' /proc/mounts)"
ip -4 addr
curl --fail --retry 3 http://10.0.2.2:8080/atlas-v5-debian13-rootfs.ext4.zst -o /tmp/rootfs.zst
test "$(sha256sum /tmp/rootfs.zst | cut -d ' ' -f1)" = "$(cat /etc/atlas-rootfs.sha256)"
zstd -t /tmp/rootfs.zst
before=$(dd if=/dev/vda bs=1M count=1 status=none | sha256sum)
if atlas-install-rootfs /dev/vda /tmp/rootfs.zst; then exit 1; fi
test "$before" = "$(dd if=/dev/vda bs=1M count=1 status=none | sha256sum)"
zstd -dc /tmp/rootfs.zst | dd of=/dev/vda bs=4M conv=fsync status=none
e2fsck -f -y /dev/vda || test "$?" = 1
resize2fs /dev/vda
mkdir -p /mnt/check
mount /dev/vda /mnt/check
test "$(cat /mnt/check/etc/hostname)" = atlas-v5
test "$(awk -F: '$1=="atlas" {print $3}' /mnt/check/etc/shadow)" = 0

test -s /mnt/check/boot/Image
umount /mnt/check
echo RESCUE_QA_PASSED
QAEOF
'''
        console.send(command)
        console.expect(r'(?m)^RESCUE_QA_PASSED\r?$', timeout=300)
        with (out / 'qa-rescue.txt').open('a') as report:
            report.write(console.before + '\nRESCUE_QA_PASSED\n'
                         'RAM boot, DHCP, rootfs SHA256, whole-disk refusal and disposable ext4 expansion passed.\n')
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        http.terminate()
        http.wait(timeout=10)
        if sock is not None:
            sock.close()
    print('STAGE: rescue QA passed', flush=True)


if __name__ == '__main__':
    main()
