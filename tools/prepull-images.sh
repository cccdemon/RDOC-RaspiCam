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
MEDIAMTX_IMAGE="chaoscrew/mediamtx-pi-ffmpeg:local"
CADDY_IMAGE="chaoscrew/caddy-cloudflare:local"
IMAGES=(
  "${MEDIAMTX_IMAGE}"
  "nginx:alpine"
  "${CADDY_IMAGE}"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/../stage-streaming/20-install-streaming/files"
OUT_TAR="${OUT_DIR}/images.tar"

mkdir -p "${OUT_DIR}"

echo "==> Building ${MEDIAMTX_IMAGE} for ${PLATFORM}"
docker build --platform "${PLATFORM}" \
  -f "${SCRIPT_DIR}/mediamtx-pi-ffmpeg.Dockerfile" \
  -t "${MEDIAMTX_IMAGE}" \
  "${SCRIPT_DIR}/.."

echo "==> Building ${CADDY_IMAGE} for ${PLATFORM}"
docker build --platform "${PLATFORM}" \
  -f "${SCRIPT_DIR}/caddy-cloudflare.Dockerfile" \
  -t "${CADDY_IMAGE}" \
  "${SCRIPT_DIR}/.."

for img in "${IMAGES[@]}"; do
  echo "==> Pulling ${img} for ${PLATFORM}"
  if [ "${img}" != "${MEDIAMTX_IMAGE}" ] && [ "${img}" != "${CADDY_IMAGE}" ]; then
    docker pull --platform "${PLATFORM}" "${img}"
  fi
done

echo "==> Saving combined tarball to ${OUT_TAR}"
docker save --platform "${PLATFORM}" -o "${OUT_TAR}" "${IMAGES[@]}"
echo "==> Size: $(du -h "${OUT_TAR}" | cut -f1)"
