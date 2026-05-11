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

camera_supports_h264() {
    local cam="$1"
    command -v v4l2-ctl >/dev/null 2>&1 || return 1
    v4l2-ctl -d "${cam}" --list-formats-ext 2>/dev/null \
        | grep -Eiq "'H264'|H\.264|H264"
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

    # 3. Resolve video path. Prefer the C920's native H.264 stream when
    #    available; it avoids software MJPEG decode and Pi re-encode load.
    VIDEO_INPUT_ARGS=""
    VIDEO_OUTPUT_ARGS=""
    VIDEO_MODE_RESOLVED="${VIDEO_MODE:-auto}"

    if [ "${VIDEO_MODE_RESOLVED}" = "auto" ]; then
        if camera_supports_h264 "${CAM_DEV}"; then
            VIDEO_MODE_RESOLVED="camera_h264"
        else
            VIDEO_MODE_RESOLVED="pi_h264"
        fi
    fi

    case "${VIDEO_MODE_RESOLVED}" in
      camera_h264)
        echo "[prepare] Video: C920 native H.264 passthrough (no re-encode)"
        VIDEO_INPUT_ARGS="-f v4l2 -input_format h264 -video_size 1920x1080 -framerate 30 -i ${CAM_DEV}"
        VIDEO_OUTPUT_ARGS="-c:v copy"
        ;;
      pi_h264)
        echo "[prepare] Video: MJPEG input -> Pi h264_v4l2m2m encoder"
        VIDEO_INPUT_ARGS="-f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i ${CAM_DEV}"
        VIDEO_OUTPUT_ARGS="-vf format=yuv420p -c:v h264_v4l2m2m -b:v 8M -maxrate 8M -bufsize 16M -g 30 -bf 0"
        ;;
      *)
        echo "[prepare] FATAL: unsupported VIDEO_MODE=${VIDEO_MODE_RESOLVED} (use auto, camera_h264, or pi_h264)" >&2
        exit 1
        ;;
    esac

    # 4. Resolve audio inputs based on AUDIO_ENABLED flag in .env.
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

    WEBRTC_HOSTS="[]"
    if [ -n "${PUBLIC_HOSTNAME:-}" ]; then
        WEBRTC_HOSTS="[${PUBLIC_HOSTNAME}]"
    elif [ -n "${CONTAINER_DOMAIN:-}" ]; then
        WEBRTC_HOSTS="[${CONTAINER_DOMAIN}]"
    fi

    # 5. Render mediamtx.pi.yml from template. We use a delimiter that won't
    #    appear in our values (`|`); audio args contain spaces and slashes
    #    that would break a `/`-delimited sed.
    sed \
        -e "s|__CAMERA_DEVICE__|${CAM_DEV}|g" \
        -e "s|__VIDEO_INPUT__|${VIDEO_INPUT_ARGS}|g" \
        -e "s|__VIDEO_OUTPUT__|${VIDEO_OUTPUT_ARGS}|g" \
        -e "s|__AUDIO_INPUT__|${AUDIO_INPUT_ARGS}|g" \
        -e "s|__AUDIO_OUTPUT__|${AUDIO_OUTPUT_ARGS}|g" \
        -e "s|__WEBRTC_ADDITIONAL_HOSTS__|${WEBRTC_HOSTS}|g" \
        mediamtx.pi.template.yml > mediamtx.pi.yml

    # 6. Export the resolved camera device for compose.override.yml.
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
        --env-file .runtime.env \
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
        --env-file .runtime.env \
        ${PROFILE_ARGS} \
        down
    ;;

  *)
    echo "Usage: $0 {prepare|up|down}" >&2
    exit 1
    ;;
esac
