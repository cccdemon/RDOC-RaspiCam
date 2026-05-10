#!/bin/bash
# Entry point for the chaoscrew-streaming systemd unit.
#
# Subcommands:
#   prepare   — load pre-pulled docker images (once), detect camera/audio,
#               render mediamtx.pi.yml from template
#   up        — docker compose up -d (with PUBLIC profile if PUBLIC_HOSTNAME set)
#   down      — docker compose down
#
# All paths are relative to /opt/server-tech.

set -euo pipefail

WORKDIR="/opt/server-tech"
cd "${WORKDIR}"

# Make .env available to this script (POSIX-friendly subset).
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------

detect_camera() {
    local cam=""
    if command -v v4l2-ctl >/dev/null 2>&1; then
        cam=$(v4l2-ctl --list-devices 2>/dev/null \
            | awk '/Logitech.*HD Pro Webcam C920/{getline; print $1}' \
            | head -1)
    fi
    if [ -z "${cam}" ]; then
        cam=$(ls /dev/video* 2>/dev/null | head -1 || true)
    fi
    echo "${cam}"
}

detect_audio_card() {
    # Returns the ALSA card number for the camera mic, or empty if none found.
    # Prefer C920 explicitly; fall back to any USB audio capture card.
    local card
    card=$(arecord -l 2>/dev/null \
        | sed -n -E 's/^card ([0-9]+):.*HD Pro Webcam C920.*/\1/p' \
        | head -1)
    if [ -z "${card}" ]; then
        card=$(arecord -l 2>/dev/null \
            | sed -n -E 's/^card ([0-9]+):.*USB.*/\1/p' \
            | head -1)
    fi
    echo "${card}"
}

# ---------------------------------------------------------------------------

case "${1:-up}" in

  prepare)
    # 1. Load pre-pulled images on first boot, then delete the tarball.
    if [ -f images.tar ]; then
        echo "[prepare] Loading pre-pulled docker images..."
        docker load -i images.tar
        rm -f images.tar
    fi

    # 2. Detect the camera.
    CAM_DEV=$(detect_camera)
    if [ -z "${CAM_DEV}" ]; then
        echo "[prepare] FATAL: no camera detected (no /dev/video*)" >&2
        exit 1
    fi
    echo "[prepare] Camera: ${CAM_DEV}"

    # 3. Resolve audio inputs based on AUDIO_ENABLED flag in .env.
    AUDIO_INPUT_ARGS=""
    AUDIO_OUTPUT_ARGS="-an"

    if [ "${AUDIO_ENABLED:-true}" = "true" ]; then
        AUDIO_CARD=$(detect_audio_card)
        if [ -n "${AUDIO_CARD}" ]; then
            ALSA_DEV="plughw:${AUDIO_CARD},0"
            echo "[prepare] Audio: ${ALSA_DEV} -> opus 96k stereo"
            AUDIO_INPUT_ARGS="-thread_queue_size 1024 -f alsa -ac 2 -ar 48000 -i ${ALSA_DEV}"
            AUDIO_OUTPUT_ARGS="-c:a libopus -b:a 96k"
        else
            echo "[prepare] WARN: AUDIO_ENABLED=true but no ALSA capture card detected — falling back to video-only" >&2
        fi
    else
        echo "[prepare] Audio: disabled (AUDIO_ENABLED=${AUDIO_ENABLED:-true})"
    fi

    # 4. Render mediamtx.pi.yml from template. We use a delimiter that won't
    #    appear in our values (`|`); audio args contain spaces and slashes
    #    that would break a `/`-delimited sed.
    sed \
        -e "s|__CAMERA_DEVICE__|${CAM_DEV}|g" \
        -e "s|__AUDIO_INPUT__|${AUDIO_INPUT_ARGS}|g" \
        -e "s|__AUDIO_OUTPUT__|${AUDIO_OUTPUT_ARGS}|g" \
        mediamtx.pi.template.yml > mediamtx.pi.yml

    # 5. Export the resolved camera device for compose.override.yml.
    {
        echo "CAMERA_DEVICE=${CAM_DEV}"
    } > .runtime.env
    ;;

  up)
    PROFILE_ARGS=""
    if [ -n "${PUBLIC_HOSTNAME:-}" ]; then
        echo "[up] Public mode: PUBLIC_HOSTNAME=${PUBLIC_HOSTNAME}"
        PROFILE_ARGS="--profile public"
    else
        echo "[up] LAN-only mode (PUBLIC_HOSTNAME not set)"
    fi

    # shellcheck disable=SC2086
    docker compose \
        -f docker-compose.yml \
        -f compose.override.yml \
        --env-file .env \
        ${PROFILE_ARGS} \
        up -d --remove-orphans
    ;;

  down)
    PROFILE_ARGS=""
    if [ -n "${PUBLIC_HOSTNAME:-}" ]; then
        PROFILE_ARGS="--profile public"
    fi
    # shellcheck disable=SC2086
    docker compose \
        -f docker-compose.yml \
        -f compose.override.yml \
        --env-file .env \
        ${PROFILE_ARGS} \
        down
    ;;

  *)
    echo "Usage: $0 {prepare|up|down}" >&2
    exit 1
    ;;
esac
