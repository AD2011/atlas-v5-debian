"""Build on an SSH-accessible native ARM64 Docker host without host apt changes."""
import argparse
import hashlib
import json
import pathlib
import re
import shlex
import subprocess
import tarfile
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--host', required=True, help='Existing trusted OpenSSH host alias')
    ap.add_argument('--out', required=True, type=pathlib.Path)
    args = ap.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._@-]*', args.host):
        ap.error('Invalid SSH alias')
    if args.out.exists():
        ap.error('Choose a new output directory')
    args.out.mkdir(parents=True)
    ssh = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', args.host]

    def remote(script, check=True):
        result = subprocess.run(ssh + ['bash -se'], input=script.encode(), capture_output=True)
        if check and result.returncode:
            raise RuntimeError(result.stderr.decode(errors='replace'))
        return result

    preflight = remote('test "$(uname -m)" = aarch64\ndocker version >/dev/null\n'
                       'printf "%s\\n" "$HOME"\n').stdout.decode().strip()
    if not preflight.startswith('/') or '\n' in preflight:
        raise RuntimeError('Unexpected remote home path')
    scratch = preflight + '/.cache/atlas-public-' + uuid.uuid4().hex[:12]
    quoted = shlex.quote(scratch)
    base = next(line.split('=', 1)[1] for line in (ROOT / 'build.env').read_text().splitlines()
                if line.startswith('BUILDER_IMAGE='))
    basequoted = shlex.quote(base)
    existed = remote(f'docker image inspect {basequoted} >/dev/null 2>&1\n', check=False).returncode == 0
    state_script = (ROOT / 'scripts/host-state.sh').read_text()
    before = remote(state_script).stdout
    (args.out / 'host-before.txt').write_bytes(before)
    with tempfile.TemporaryDirectory() as temp:
        archive = pathlib.Path(temp) / 'source.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for name in ('build.sh', 'build.env', 'scripts', 'tools', 'README.md', 'LICENSE'):
                tar.add(ROOT / name, arcname=name)
            if (ROOT / 'local/authorized_keys').is_file():
                tar.add(ROOT / 'local/authorized_keys', arcname='local/authorized_keys')
        remote(f'mkdir -p {quoted}/source\n')
        subprocess.run(['scp', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                        str(archive), args.host + ':' + scratch + '/source.tar.gz'], check=True)
    try:
        remote(f'tar -xzf {quoted}/source.tar.gz -C {quoted}/source\n')
        print('Remote scratch: ' + scratch, flush=True)
        process = subprocess.Popen(ssh + ['bash -se'], stdin=subprocess.PIPE)
        process.communicate(f'cd {quoted}/source\nbash build.sh\n'.encode())
        release = args.out / 'release.tar.gz'
        with release.open('wb') as f:
            subprocess.run(ssh + ['tar -C ' + quoted + '/source/dist -czf - .'], stdout=f, check=True)
        with tarfile.open(release) as tar:
            tar.extractall(args.out / ('failed-dist' if process.returncode else 'dist'), filter='data')
        release.unlink()
        if process.returncode:
            raise RuntimeError('Remote build failed; inspect failed-dist/build.log. Do not publish these files.')
        for line in (args.out / 'dist/SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ', 1)
            path = args.out / 'dist' / name
            if path.parent != args.out / 'dist':
                raise RuntimeError('Invalid manifest path')
            with path.open('rb') as f:
                assert hashlib.file_digest(f, 'sha256').hexdigest() == digest, name
        print('All downloaded release hashes verified.', flush=True)
    finally:
        logs = remote(f'find {quoted}/source -name build.log -type f -exec cat {{}} \\;\n', check=False)
        (args.out / 'remote-build.log').write_bytes(logs.stdout)
        cleanup_script = f'''case {quoted} in "$HOME"/.cache/atlas-public-*) ;; *) exit 1 ;; esac
for name in $(docker ps -a --format "{{{{.Names}}}}" | grep "^atlas-v5-build" || true); do
    mounts=$(docker inspect -f "{{{{range .Mounts}}}}{{{{.Source}}}} {{{{end}}}}" "$name")
    case "$mounts" in {quoted}/source/.build-*) docker rm -f "$name" ;; esac
done
rm -rf -- {quoted}
'''
        if not existed:
            cleanup_script += f'docker image rm {basequoted} || true\n'
        cleanup = remote(cleanup_script, check=False)
        (args.out / 'cleanup.txt').write_bytes(cleanup.stdout + cleanup.stderr)
        after = remote(state_script).stdout
        (args.out / 'host-after.txt').write_bytes(after)
        report = {'host_state_equal': before == after, 'remote_scratch_removed': cleanup.returncode == 0,
                  'builder_image_existed_before': existed}
        (args.out / 'host-audit.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Host audit: ' + json.dumps(report), flush=True)
        if before != after:
            print('Host inventory changed; compare host-before/after. Independent changes were preserved.', flush=True)


if __name__ == '__main__':
    main()
