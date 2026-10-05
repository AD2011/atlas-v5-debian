#!/bin/sh
set -eu
echo 'HOST_PACKAGES_SHA256'
dpkg-query -W -f='${Package}\t${Version}\n' | LC_ALL=C sort | sha256sum
echo 'HOST_CONFIGURATION_SHA256'
find /etc/apt /etc/docker /etc/systemd/system -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum
sha256sum /etc/os-release /etc/passwd /etc/group /etc/subuid /etc/subgid
echo 'DOCKER_IMAGES'
docker image ls --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}' | LC_ALL=C sort
echo 'DOCKER_CONTAINERS'
docker ps -a --no-trunc --format '{{.ID}} {{.Names}} {{.Image}} {{.State}}' | LC_ALL=C sort
echo 'HOST_KERNEL'
uname -r
