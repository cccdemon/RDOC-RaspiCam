#!/bin/bash -e

# Install Docker Engine + Compose plugin into the chroot.
# We use the convenience script from get.docker.com — it handles the Debian repo
# setup, signing key, and apt install of docker-ce + docker-compose-plugin.
#
# Note: docker.service won't start inside the chroot (no daemon). That is fine —
# we only need the package installed. First boot starts the daemon normally.

on_chroot << 'EOF'
set -e

# get.docker.com expects /etc/os-release; pi-gen rootfs has it.
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm -f /tmp/get-docker.sh

# Ensure docker-compose-plugin is present (the convenience script ships it,
# but verify so we fail loud if upstream changes).
dpkg -s docker-compose-plugin >/dev/null

# Add the default user (created by pi-gen via FIRST_USER_NAME) to the docker group.
# This lets the user run `docker compose ps` over SSH without sudo.
usermod -aG docker streamer 2>/dev/null || true

# Enable docker so the daemon starts at boot.
systemctl enable docker.service

# containerd is enabled by docker.service automatically.
EOF
