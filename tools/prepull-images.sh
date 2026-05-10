#!/bin/bash
# Pre-pull the ARM64 docker images that the streaming stack needs and save them
# to a single tarball. The pi-gen Stage 20 copies the tarball into the rootfs;
# the first-boot script does `docker load` so the Pi never has to pull from the
# network on its first run.
#
# Run this on the build host (CI or WSL2) BEFORE invoking pi-gen.
# Requires: docker with linux/arm64 emulation (binfmt_misc + qemu-user-static).

set -euo pipefail

PLATFORM=linux/arm64
IMAGES=(
  "bluenviron/mediamtx:1-ffmpeg-rpi"
  "nginx:alpine"
  "caddy:2-alpine"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/../stage-streaming/20-install-streaming/files"
OUT_TAR="${OUT_DIR}/images.tar"

mkdir -p "${OUT_DIR}"

for img in "${IMAGES[@]}"; do
  echo "==> Pulling ${img} for ${PLATFORM}"
  docker pull --platform "${PLATFORM}" "${img}"
done

echo "==> Saving combined tarball to ${OUT_TAR}"
docker save --platform "${PLATFORM}" -o "${OUT_TAR}" "${IMAGES[@]}"
echo "==> Size: $(du -h "${OUT_TAR}" | cut -f1)"
