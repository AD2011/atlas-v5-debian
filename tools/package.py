"""Verify boot load ranges and package only release files."""
import hashlib
import pathlib
import struct
import zipfile

OUT = pathlib.Path('/work/out')
PAYLOADS = ['Image', 'armada-3720-atlas-v5.dtb', 'atlas-v5-rescue.cpio.gz',
            'atlas-v5-debian13-rootfs.ext4.zst']
header = (OUT / 'Image').read_bytes()[:64]
offset, extent, flags = struct.unpack_from('<QQQ', header, 8)
assert struct.unpack_from('<I', header, 56)[0] == 0x644d5241
assert offset == 0 and flags & 8, 'Recompute addresses for this Image header'
assert extent >= (OUT / 'Image').stat().st_size
ranges = [('PSCI', 0x04000000, 0x04200000), ('TEE', 0x04400000, 0x05400000),
          ('DTB + 64KiB', 0x05f00000, 0x05f00000 + (OUT / PAYLOADS[1]).stat().st_size + 65536),
          ('Kernel extent', 0x06000000, 0x06000000 + extent),
          ('Rescue payload', 0x08000000, 0x08000000 + (OUT / PAYLOADS[2]).stat().st_size),
          ('U-Boot', 0x1fafd150, 0x20000000)]
lines = []
for i, (name, start, end) in enumerate(ranges):
    assert 0 <= start < end <= 0x20000000
    for other, low, high in ranges[:i]:
        assert end <= low or high <= start, f'{name} overlaps {other}'
    lines.append(f'{name}: [{start:#010x}, {end:#010x})')
(OUT / 'memory-layout.txt').write_text('\n'.join(lines) + '\n')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


(OUT / 'probe-SHA256SUMS').write_text(''.join(digest(OUT / name) + '  ' + name + '\n' for name in PAYLOADS))
with zipfile.ZipFile(OUT / 'atlas-v5-probe-files.zip', 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as archive:
    for name in PAYLOADS:
        archive.write(OUT / name, name)
    archive.write(OUT / 'probe-SHA256SUMS', 'SHA256SUMS')
    archive.write('/work/input/README.md', 'README.md')
    archive.write('/work/input/LICENSE', 'LICENSE')
inputs = pathlib.Path('/work/input')
for name in ('README.md', 'LICENSE'):
    (OUT / name).write_bytes((inputs / name).read_bytes())
# A runtime log is copied by the EXIT trap after packaging; omit it from the
# manifest to avoid hashing a log that is still being written.
files = sorted(p for p in OUT.iterdir() if p.is_file() and p.name not in ('SHA256SUMS', 'build.log'))
(OUT / 'SHA256SUMS').write_text(''.join(digest(p) + '  ' + p.name + '\n' for p in files))
print('STAGE: verified load ranges; release ZIP and manifests created', flush=True)
