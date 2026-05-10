#!/bin/bash -e

install -v -m 644 files/chaoscrew-streaming.service "${ROOTFS_DIR}/etc/systemd/system/chaoscrew-streaming.service"
install -v -m 644 files/streaming.avahi-service     "${ROOTFS_DIR}/etc/avahi/services/streaming.service"
install -v -m 644 files/log2ram.conf                "${ROOTFS_DIR}/etc/log2ram.conf"
install -v -m 644 files/99-camera-rebind.rules      "${ROOTFS_DIR}/etc/udev/rules.d/99-camera-rebind.rules"
install -v -m 644 files/motd                        "${ROOTFS_DIR}/etc/motd"

on_chroot << 'EOF'
set -e

# log2ram is shipped by Debian as a service that may need explicit enable
systemctl enable log2ram.service 2>/dev/null || true

# avahi advertises chaoscrew.local + the streaming HTTP service
systemctl enable avahi-daemon.service

# Chrony for NTP — Pi has no RTC, ACME and TLS need correct time
systemctl enable chrony.service

# Disable swap — saves SD writes; Pi 4 (4/8 GB) has plenty of RAM for ffmpeg
systemctl disable dphys-swapfile.service 2>/dev/null || true

# The streaming service itself — will fail-loud at runtime if /opt/server-tech is missing
systemctl enable chaoscrew-streaming.service

# Camera-rebind udev rule trigger
udevadm control --reload-rules 2>/dev/null || true
EOF
