#!/bin/bash -e

# Server-Tech repo + ref come from pi-gen.config (overridable via env at build time).
SERVER_TECH_REPO="${SERVER_TECH_REPO:-raumdock/Server-tech}"
SERVER_TECH_REF="${SERVER_TECH_REF:-main}"

echo "Cloning ${SERVER_TECH_REPO}@${SERVER_TECH_REF} into /opt/server-tech (in chroot)..."

on_chroot << EOF
set -e
rm -rf /opt/server-tech
git clone --depth=1 --branch "${SERVER_TECH_REF}" \
    "https://github.com/${SERVER_TECH_REPO}.git" \
    /opt/server-tech \
  || git clone "https://github.com/${SERVER_TECH_REPO}.git" /opt/server-tech
cd /opt/server-tech
git checkout "${SERVER_TECH_REF}" 2>/dev/null || true
echo "Cloned: \$(git log -1 --oneline)"
EOF

# Pi-specific overrides — copied on top of the cloned tree.
install -v -m 644 files/compose.override.yml      "${ROOTFS_DIR}/opt/server-tech/compose.override.yml"
install -v -m 644 files/mediamtx.pi.template.yml  "${ROOTFS_DIR}/opt/server-tech/mediamtx.pi.template.yml"
install -v -m 644 files/Caddyfile                 "${ROOTFS_DIR}/opt/server-tech/Caddyfile"
install -v -m 644 files/env.template              "${ROOTFS_DIR}/opt/server-tech/.env"
install -v -m 755 files/start-streaming.sh        "${ROOTFS_DIR}/opt/server-tech/start-streaming.sh"

# Pre-pulled docker images — optional, big tarball produced by tools/prepull-images.sh.
if [ -f files/images.tar ]; then
    install -v -m 644 files/images.tar "${ROOTFS_DIR}/opt/server-tech/images.tar"
    echo "Pre-pulled images bundled ($(du -h files/images.tar | cut -f1))"
else
    echo "WARN: no pre-pulled images.tar — first boot will pull from network (~5 min)"
fi

# Runtime dirs that compose expects (logs/recordings).
install -d -m 755 "${ROOTFS_DIR}/opt/server-tech/logs"
install -d -m 755 "${ROOTFS_DIR}/opt/server-tech/recordings"

# Caddy data dir for Let's-Encrypt certs (only used when PUBLIC_HOSTNAME is set).
install -d -m 755 "${ROOTFS_DIR}/opt/server-tech/caddy_data"

# Make sure permissions are sane — the streamer user (uid 1000) needs write access
# to logs/, recordings/, .env, .runtime.env, and the rendered mediamtx.pi.yml.
on_chroot << 'EOF'
chown -R 1000:1000 /opt/server-tech || true
EOF
