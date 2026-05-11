#!/usr/bin/env bash
set -euo pipefail

# Install Chaos Crew streaming onto a stock Raspberry Pi OS Lite 64-bit system.
#
# Expected use on the Pi:
#   git clone https://github.com/cccdemon/RDOC-RaspiCam.git
#   cd RDOC-RaspiCam
#   sudo scripts/install-on-pi.sh
#
# Optional overrides:
#   SERVER_TECH_REPO=cccdemon/homecam-docker SERVER_TECH_REF=main sudo -E scripts/install-on-pi.sh

SERVER_TECH_REPO="${SERVER_TECH_REPO:-cccdemon/homecam-docker}"
SERVER_TECH_REF="${SERVER_TECH_REF:-main}"
SERVER_TECH_DIR="${SERVER_TECH_DIR:-/opt/server-tech}"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-chaoscrew}"
ENABLE_SD_TUNING="${ENABLE_SD_TUNING:-true}"
ENABLE_WATCHDOG="${ENABLE_WATCHDOG:-true}"

if [ "${EUID}" -ne 0 ]; then
    exec sudo -E bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PI_FILES="${REPO_DIR}/stage-streaming"

require_file() {
    if [ ! -f "$1" ]; then
        echo "FATAL: missing required file: $1" >&2
        exit 1
    fi
}

install_unit_files() {
    install -D -m 644 "${PI_FILES}/00-install-system/files/chaoscrew-streaming.service" \
        /etc/systemd/system/chaoscrew-streaming.service
    install -D -m 644 "${PI_FILES}/00-install-system/files/streaming.avahi-service" \
        /etc/avahi/services/streaming.service
    install -D -m 644 "${PI_FILES}/00-install-system/files/99-camera-rebind.rules" \
        /etc/udev/rules.d/99-camera-rebind.rules
    install -m 644 "${PI_FILES}/00-install-system/files/motd" /etc/motd
}

install_server_tech() {
    if [ -d "${SERVER_TECH_DIR}/.git" ]; then
        git -C "${SERVER_TECH_DIR}" fetch --depth=1 origin "${SERVER_TECH_REF}" || git -C "${SERVER_TECH_DIR}" fetch origin
        git -C "${SERVER_TECH_DIR}" checkout -f FETCH_HEAD
    else
        rm -rf "${SERVER_TECH_DIR}"
        git clone --depth=1 --branch "${SERVER_TECH_REF}" \
            "https://github.com/${SERVER_TECH_REPO}.git" \
            "${SERVER_TECH_DIR}" \
          || git clone "https://github.com/${SERVER_TECH_REPO}.git" "${SERVER_TECH_DIR}"
        git -C "${SERVER_TECH_DIR}" checkout "${SERVER_TECH_REF}" 2>/dev/null || true
    fi

    install -m 644 "${PI_FILES}/20-install-streaming/files/compose.override.yml" "${SERVER_TECH_DIR}/compose.override.yml"
    install -m 644 "${PI_FILES}/20-install-streaming/files/mediamtx.pi.template.yml" "${SERVER_TECH_DIR}/mediamtx.pi.template.yml"
    install -m 644 "${PI_FILES}/20-install-streaming/files/Caddyfile" "${SERVER_TECH_DIR}/Caddyfile"
    install -m 755 "${PI_FILES}/20-install-streaming/files/start-streaming.sh" "${SERVER_TECH_DIR}/start-streaming.sh"

    if [ ! -f "${SERVER_TECH_DIR}/.env" ]; then
        install -m 644 "${PI_FILES}/20-install-streaming/files/env.template" "${SERVER_TECH_DIR}/.env"
    fi

    install -d -m 755 "${SERVER_TECH_DIR}/logs" "${SERVER_TECH_DIR}/recordings" "${SERVER_TECH_DIR}/caddy_data"
    chown -R 1000:1000 "${SERVER_TECH_DIR}" 2>/dev/null || true
}

install_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
    fi

    if ! docker compose version >/dev/null 2>&1; then
        apt-get update
        apt-get install -y docker-compose-plugin
    fi

    systemctl enable --now docker.service

    if [ -n "${SUDO_USER:-}" ] && id "${SUDO_USER}" >/dev/null 2>&1; then
        usermod -aG docker "${SUDO_USER}" || true
    fi
}

build_runtime_images() {
    docker build --platform linux/arm64 \
        -f "${REPO_DIR}/tools/mediamtx-pi-ffmpeg.Dockerfile" \
        -t chaoscrew/mediamtx-pi-ffmpeg:local \
        "${REPO_DIR}"

    docker build --platform linux/arm64 \
        -f "${REPO_DIR}/tools/caddy-cloudflare.Dockerfile" \
        -t chaoscrew/caddy-cloudflare:local \
        "${REPO_DIR}"

    docker pull --platform linux/arm64 nginx:alpine
}

apply_sd_tuning() {
    if [ "${ENABLE_SD_TUNING}" != "true" ]; then
        return 0
    fi

    local cmdline="/boot/firmware/cmdline.txt"
    if [ -f "${cmdline}" ] && ! grep -q 'commit=600' "${cmdline}"; then
        sed -i 's/\(rootwait\)/\1 commit=600/' "${cmdline}"
    fi

    if ! grep -q 'tmpfs /var/log' /etc/fstab; then
        echo "tmpfs /var/log tmpfs defaults,noatime,nosuid,nodev,size=128M,mode=755 0 0" >> /etc/fstab
    fi
}

apply_watchdog() {
    if [ "${ENABLE_WATCHDOG}" != "true" ]; then
        return 0
    fi

    local config="/boot/firmware/config.txt"
    if [ -f "${config}" ] && ! grep -q '^dtparam=watchdog=on' "${config}"; then
        {
            echo ""
            echo "# Chaos Crew streaming: enable hardware watchdog"
            echo "dtparam=watchdog=on"
        } >> "${config}"
    fi

    install -D -m 644 "${PI_FILES}/30-finalize/files/streaming.watchdog.conf" \
        /etc/systemd/system.conf.d/10-streaming-watchdog.conf
}

disable_unused_services() {
    systemctl disable bluetooth.service 2>/dev/null || true
    systemctl disable hciuart.service 2>/dev/null || true
    systemctl disable triggerhappy.service 2>/dev/null || true
    systemctl disable dphys-swapfile.service 2>/dev/null || true
}

main() {
    require_file "${REPO_DIR}/tools/mediamtx-pi-ffmpeg.Dockerfile"
    require_file "${REPO_DIR}/tools/caddy-cloudflare.Dockerfile"
    require_file "${PI_FILES}/20-install-streaming/files/compose.override.yml"

    echo "==> Setting hostname: ${HOSTNAME_VALUE}"
    hostnamectl set-hostname "${HOSTNAME_VALUE}" || true

    echo "==> Installing base packages"
    apt-get update
    apt-get install -y \
        avahi-daemon avahi-utils \
        v4l-utils alsa-utils \
        jq chrony ca-certificates curl git \
        udev

    echo "==> Installing Docker"
    install_docker

    echo "==> Installing Server-tech ${SERVER_TECH_REPO}@${SERVER_TECH_REF}"
    install_server_tech

    echo "==> Building/pulling runtime container images"
    build_runtime_images

    echo "==> Installing systemd, avahi, and udev integration"
    install_unit_files
    systemctl enable avahi-daemon.service
    systemctl enable chrony.service
    systemctl enable chaoscrew-streaming.service
    udevadm control --reload-rules 2>/dev/null || true

    echo "==> Applying appliance tuning"
    apply_sd_tuning
    apply_watchdog
    disable_unused_services

    systemctl daemon-reload

    echo "==> Preparing stream config"
    "${SERVER_TECH_DIR}/start-streaming.sh" prepare

    echo "==> Starting stream service"
    systemctl restart chaoscrew-streaming.service

    echo
    echo "Install complete."
    echo "Open: http://${HOSTNAME_VALUE}.local"
    echo "Status: systemctl status chaoscrew-streaming"
}

main "$@"
