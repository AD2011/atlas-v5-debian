"""Stream a read-only eMMC backup through SSH without Windows text redirection.

First connect interactively to verify the rescue SSH host fingerprint. This
helper requires an already trusted host and public-key authentication.
"""
import argparse
import hashlib
import pathlib
import re
import shutil
import subprocess
import tempfile

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--host', required=True, help='Probe IP address, without user or port')
    ap.add_argument('--out', required=True, type=pathlib.Path)
    ap.add_argument('--device', default='/dev/mmcblk0')
    ap.add_argument('--port', default=2222, type=int)
    ap.add_argument('--ssh-config', type=pathlib.Path,
                    help='Optional SSH config, e.g. with an isolated UART-verified host key')
    args = ap.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.:-]*', args.host):
        ap.error('Invalid host')
    if not re.fullmatch(r'/dev/mmcblk[0-9]+', args.device):
        ap.error('Device must be an eMMC user-area disk, such as /dev/mmcblk0')
    if not 1 <= args.port <= 65535:
        ap.error('Invalid port')
    base = ['ssh']
    if args.ssh_config:
        if not args.ssh_config.is_file():
            ap.error('SSH config file not found')
        base += ['-F', str(args.ssh_config.resolve())]
    base += ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'ConnectTimeout=15', '-p', str(args.port), 'root@' + args.host]
    def remote(command):
        p = subprocess.run(base + [command], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if p.returncode:
            raise RuntimeError(p.stderr.decode(errors='replace'))
        return p.stdout

    # Compare kernel device numbers, so mount aliases cannot bypass this check.
    numbers = set(remote('lsblk -nr -o MAJ:MIN ' + args.device).decode().split())
    if not numbers:
        raise RuntimeError('eMMC user area not found')
    mounted = {line.split()[2] for line in
               remote('cat /proc/self/mountinfo').decode().splitlines()}
    if numbers & mounted:
        raise RuntimeError('eMMC is mounted; boot the RAM rescue first')
    parsed = []
    for device in (args.device, args.device + 'boot0', args.device + 'boot1'):
        size = int(remote('test -b ' + device + ' && blockdev --getsize64 ' + device))
        parsed.append((device, size))
    args.out.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(args.out).free < sum(size for _, size in parsed) + 64 * 1024 * 1024:
        raise RuntimeError('Insufficient local disk space for a full eMMC backup')
    inventory = remote('uname -a; lsblk -b -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,MOUNTPOINTS; '
                       'blkid; sfdisk --dump ' + args.device + '; cat /proc/mounts; '
                       'cat /proc/device-tree/model 2>/dev/null; true')
    with (args.out / 'probe-storage-before.txt').open('xb') as f:
        f.write(inventory)
    sums = []
    for device, size in parsed:
        name = pathlib.PurePosixPath(device).name + '.img'
        final = args.out / name
        partial = args.out / (name + '.partial')
        if final.exists():
            raise RuntimeError('Refusing to overwrite an existing backup: ' + str(final))
        print('Backing up ' + device + ' (' + str(size) + ' bytes)', flush=True)
        digest = hashlib.sha256()
        count = 0
        with partial.open('xb') as output, tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(base + ['dd if=' + device + ' bs=4M status=none'],
                                       stdout=subprocess.PIPE, stderr=errors)
            try:
                while True:
                    chunk = process.stdout.read(4 * 1024 * 1024)
                    if not chunk:
                        break
                    output.write(chunk)
                    digest.update(chunk)
                    count += len(chunk)
                result = process.wait()
            except BaseException:
                process.kill()
                process.wait()
                raise
            finally:
                process.stdout.close()
            errors.seek(0)
            if result:
                raise RuntimeError(errors.read().decode(errors='replace'))
        if count != size:
            raise RuntimeError('Backup size mismatch; partial file retained')
        expected = remote('sha256sum ' + device).decode().split()[0]
        if digest.hexdigest() != expected:
            raise RuntimeError('Backup checksum mismatch; partial file retained')
        partial.rename(final)
        sums.append(expected + '  ' + name)
        print('Verified ' + name + ': ' + expected, flush=True)
    with (args.out / 'SHA256SUMS').open('x', encoding='ascii', newline='\n') as f:
        f.write('\n'.join(sums) + '\n')
    print('Backup complete. Also save the full UART log and U-Boot printenv output here.')

if __name__ == '__main__':
    main()
