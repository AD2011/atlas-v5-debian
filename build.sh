#!/bin/bash
# Native ARM64 build. All package installation happens in a disposable container.
set -euo pipefail
cd -- "$(dirname -- "$0")"
source ./build.env
test "$(uname -m)" = aarch64 || { echo 'Use a native ARM64 Linux host with Docker.' >&2; exit 1; }
command -v docker >/dev/null
test ! -e dist || { echo 'Move or remove dist/ before a fresh build.' >&2; exit 1; }
work=$(mktemp -d "$PWD/.build-XXXXXXXX")
container="atlas-v5-$(basename "$work" | tr -cd 'a-zA-Z0-9')"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    # Recover ownership even if a signal prevented the builder's EXIT trap.
    if test "${KEEP_WORK:-0}" != 1; then
        case "$work" in "$PWD"/.build-*) ;; *) return 1 ;; esac
        docker run --rm -v "$work:/work" "$BUILDER_IMAGE" \
            chown -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 || true
        rm -rf -- "$work"
    fi
}
trap cleanup EXIT
mkdir -p "$work/input" "$work/out"
cp -a scripts tools README.md LICENSE build.env "$work/input/"
if test -f local/authorized_keys; then
    cp local/authorized_keys "$work/input/authorized_keys"
else
    : > "$work/input/authorized_keys"
fi
docker pull "$BUILDER_IMAGE"
if docker run --name "$container" --cpus "${BUILD_CPUS:-3}" --memory "${BUILD_MEMORY:-8g}" \
    --pids-limit 512 --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
    -v "$work:/work" -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    -e "JOBS=${JOBS:-3}" -e "BUILDER_IMAGE_DIGEST=$BUILDER_IMAGE" \
    "$BUILDER_IMAGE" bash /work/input/scripts/build-all.sh; then
    status=0
else
    status=$?
fi
mkdir dist
cp -a "$work/out/." dist/
test "$status" = 0 || { echo 'Build failed; inspect dist/build.log.' >&2; exit "$status"; }
(cd dist; sha256sum -c SHA256SUMS)
echo 'Build and QEMU verification passed. Files are in dist/.'
