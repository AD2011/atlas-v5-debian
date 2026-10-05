"""Boot the pristine ext4 with QEMU snapshot=on; never save QA mutations."""
import hashlib
import io
import logging
import pathlib
import secrets
import socket
import subprocess
import time

import paramiko
import pexpect.fdpexpect

OUT = pathlib.Path('/work/out')
QA = pathlib.Path('/work/qa')
QA.mkdir(exist_ok=True)
IMAGE = OUT / 'atlas-v5-debian13-rootfs.ext4'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def serial_connect(path, process):
    for _ in range(300):
        if process.poll() is not None:
            raise RuntimeError('QEMU exited before serial connection')
        sock = socket.socket(socket.AF_UNIX)
        try:
            sock.connect(str(path))
            return sock, pexpect.fdpexpect.fdspawn(sock, encoding='utf-8', timeout=300)
        except (FileNotFoundError, ConnectionRefusedError):
            sock.close()
            time.sleep(0.1)
    raise RuntimeError('QEMU serial socket unavailable')


def ssh(password):
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())  # Isolated, disposable QEMU.
    client.connect('127.0.0.1', port=2222, username='atlas', password=password,
                   look_for_keys=False, allow_agent=False, timeout=5, banner_timeout=5, auth_timeout=10)
    return client


def enter(console, text):
    # fdspawn.sendline lacks spawn's send delay. PAM prints a prompt before
    # changing terminal mode; immediate input can be flushed by tcsetattr.
    time.sleep(0.3)
    console.sendline(text)


def main():
    original = sha(IMAGE)
    sockpath = QA / 'serial.sock'
    sockpath.unlink(missing_ok=True)
    args = ['qemu-system-aarch64', '-machine', 'virt', '-cpu', 'cortex-a53',
            '-m', '512', '-smp', '2', '-accel', 'tcg,thread=multi',
            '-kernel', str(OUT / 'Image'),
            '-append', 'root=/dev/vda rootfstype=ext4 rootwait console=ttyAMA0,115200n8 rw',
            '-drive', f'if=none,id=root,file={IMAGE},format=raw,snapshot=on',
            '-device', 'virtio-blk-device,drive=root',
            '-netdev', 'user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22',
            '-device', 'virtio-net-device,netdev=net0',
            '-object', 'rng-random,id=rng0,filename=/dev/urandom',
            '-device', 'virtio-rng-device,rng=rng0', '-display', 'none', '-monitor', 'none',
            '-serial', f'unix:{sockpath},server=on,wait=on']
    with (QA / 'qemu-stderr.log').open('w') as errors:
        process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=errors)
        sock = None
        try:
            sock, console = serial_connect(sockpath, process)
            transcript = io.StringIO()
            console.logfile_read = transcript
            console.expect(r'atlas-v5 login:')
            (OUT / 'qemu-boot.log').write_text(console.before)
            # The default password must not be exposed through SSH.
            try:
                with socket.create_connection(('127.0.0.1', 2222), timeout=3) as check:
                    check.settimeout(3)
                    banner = check.recv(128)
                    assert not banner.startswith(b'SSH-'), 'SSH reachable before password change'
            except (ConnectionError, TimeoutError, socket.timeout):
                pass
            enter(console, 'atlas')
            console.expect(r'Password:')
            enter(console, 'Ch@nge!Me(26)')
            console.expect(r'(?i)current password:')
            enter(console, 'Ch@nge!Me(26)')
            new_password = 'QA-' + secrets.token_urlsafe(24)
            console.expect(r'(?i)new password:')
            enter(console, new_password)
            console.expect(r'(?i)retype new password:')
            enter(console, new_password)
            # login's PAM dialogue can return to login or open a shell without
            # passwd(1)'s success message. SSH authentication verifies the change.
            try:
                console.expect(r'atlas-v5 login:|(?m:^[^\r\n]*[$#] )', timeout=30)
            except pexpect.exceptions.TIMEOUT:
                (OUT / 'qa-authentication-failure.txt').write_text(
                    transcript.getvalue().replace(new_password, '[QA password redacted]'))
                raise RuntimeError('Console password change did not finish; see qa-authentication-failure.txt')
            (OUT / 'qa-first-login.txt').write_text(
                transcript.getvalue().replace(new_password, '[QA password redacted]'))
            if 'login:' in console.after:
                enter(console, 'atlas')
                console.expect(r'Password:')
                enter(console, new_password)
                console.expect(r'(?m:^[^\r\n]*[$] )', timeout=30)
            enter(console, "sudo -S -p 'QA_SUDO_PASSWORD: ' bash --noprofile --norc")
            console.expect('QA_SUDO_PASSWORD:')
            enter(console, new_password)
            console.expect(r'bash-[0-9.]+#', timeout=30)
            enter(console, '''date -u; awk -F: '$1=="atlas" {print "Password last-change day:",$3}' /etc/shadow; /usr/local/sbin/atlas-password-changed; echo "SSH condition status:$?"; systemctl status dropbear atlas-ssh-unlock.path atlas-ssh-unlock.service --no-pager; journalctl -u dropbear -u atlas-ssh-unlock.service --no-pager; echo QA_CONSOLE_DETAILS_DONE''')
            console.expect(r'(?m)^QA_CONSOLE_DETAILS_DONE\r?$', timeout=30)
            (OUT / 'qa-console.txt').write_text(
                console.before.replace(new_password, '[QA password redacted]'))
            client = None
            logging.getLogger('paramiko.transport').setLevel(logging.CRITICAL)
            for _ in range(20):
                try:
                    client = ssh(new_password)
                    break
                except (OSError, paramiko.SSHException):
                    time.sleep(2)
            if client is None:
                try:
                    console.expect(r'atlas-v5 login:|[$#] ', timeout=5)
                    detail = transcript.getvalue()
                except pexpect.exceptions.TIMEOUT:
                    detail = transcript.getvalue()
                (OUT / 'qa-authentication-failure.txt').write_text(
                    detail.replace(new_password, '[QA password redacted]'))
                raise RuntimeError('SSH did not start after console password change; see qa-authentication-failure.txt')
            script = 'test "$(uname -r)" = ' + (OUT / 'kernel-release.txt').read_text().strip() + '\n' + pathlib.Path('/work/input/scripts/qa-guest.sh').read_text()
            stdin, stdout, stderr = client.exec_command("sudo -S -p '' bash -se", timeout=300)
            stdin.write(new_password + '\n' + script)
            stdin.flush()
            stdin.channel.shutdown_write()
            result = stdout.read().decode()
            errors_text = stderr.read().decode()
            status = stdout.channel.recv_exit_status()
            client.close()
            (OUT / 'qa-image.txt').write_text(result + errors_text)
            assert status == 0, f'Guest verification failed: {status}\n{result}\n{errors_text}'
            try:
                rejected = ssh('Ch@nge!Me(26)')
            except paramiko.AuthenticationException:
                pass
            else:
                rejected.close()
                raise RuntimeError('Default password still accepted after change')
        finally:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            if sock is not None:
                sock.close()
    assert sha(IMAGE) == original, 'QA modified the distributable image'
    with (OUT / 'qa-image.txt').open('a') as report:
        report.write('First console password change enforced; SSH disabled beforehand.\n'
                     'SSH enabled with new password; original password rejected.\n'
                     'Pristine ext4 SHA256 unchanged by snapshot QA.\n')
    print('STAGE: QEMU image and first-login authentication verification passed', flush=True)


if __name__ == '__main__':
    main()
