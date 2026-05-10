#!/bin/bash -e

# 1. ext4 mount option commit=600 — defer fsync up to 10 min instead of 5s.
#    Significant SD-card-write reduction, acceptable risk on a streaming-only Pi.
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
if [ -f "${CMDLINE}" ] && ! grep -q 'commit=600' "${CMDLINE}"; then
    # Append to the existing single-line cmdline.
    sed -i 's/\(rootwait\)/\1 commit=600/' "${CMDLINE}"
fi

# 2. Hardware watchdog — Pi 4 BCM2711 has a built-in WDT; firmware needs to enable it.
CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"
if [ -f "${CONFIG_TXT}" ] && ! grep -q '^dtparam=watchdog=on' "${CONFIG_TXT}"; then
    {
        echo ""
        echo "# Streaming image: enable hardware watchdog (chaoscrew-streaming)"
        echo "dtparam=watchdog=on"
    } >> "${CONFIG_TXT}"
fi

# 3. systemd watchdog config — reboot Pi after 15s of no kick.
install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system.conf.d"
install -v -m 644 files/streaming.watchdog.conf \
    "${ROOTFS_DIR}/etc/systemd/system.conf.d/10-streaming-watchdog.conf"

on_chroot << 'EOF'
set -e

# 4. Disable bluetooth + UART services. Streaming Pi has no use for them
#    and they free ~10 MB RAM and prevent UART probing on the GPIO header.
systemctl disable bluetooth.service 2>/dev/null || true
systemctl disable hciuart.service 2>/dev/null || true

# 5. Disable triggerhappy (button-event daemon for desktop) — not needed on Lite.
systemctl disable triggerhappy.service 2>/dev/null || true

# 6. Final swap-off: stage 00 also disables dphys-swapfile, but verify here.
systemctl disable dphys-swapfile.service 2>/dev/null || true
EOF
