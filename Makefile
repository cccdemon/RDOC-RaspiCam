# RaspiImage Makefile — Pi 4 streaming image build & flash helpers.
#
# Targets:
#   image          — trigger the GitHub Actions build, download the artifact into deploy/
#   image-local    — run pi-gen in WSL2 locally (best-effort, slower, less reproducible)
#   flash-prep     — print Raspberry Pi Imager instructions (SD card on G:)
#   verify         — sha256-check the latest deploy/ image
#   clean          — wipe deploy/ build artifacts
#   mediamtx-check — verify v4l2m2m support in the upstream mediamtx ARM64 image

SHELL := /bin/bash
DEPLOY_DIR := deploy
GH_WORKFLOW := build-image.yml
GH_REF := main

.PHONY: image image-local flash-prep verify clean mediamtx-check help

help:
	@echo "Targets: image, image-local, flash-prep, verify, clean, mediamtx-check"

image:
	@command -v gh >/dev/null || { echo "gh CLI required (https://cli.github.com)"; exit 1; }
	@echo "Triggering GitHub Actions workflow $(GH_WORKFLOW)..."
	gh workflow run $(GH_WORKFLOW) --ref $(GH_REF)
	@echo "Polling latest run..."
	@sleep 5
	@RUN_ID=$$(gh run list --workflow=$(GH_WORKFLOW) --limit 1 --json databaseId -q '.[0].databaseId'); \
	  echo "Watching run $$RUN_ID"; \
	  gh run watch $$RUN_ID --interval 30; \
	  mkdir -p $(DEPLOY_DIR); \
	  gh run download $$RUN_ID --dir $(DEPLOY_DIR)
	@ls -lh $(DEPLOY_DIR)/

SERVER_TECH_REPO ?= cccdemon/homecam-docker
SERVER_TECH_REF  ?= main

image-local:
	@command -v wsl >/dev/null || { echo "WSL2 required for local build"; exit 1; }
	@echo "Running pi-gen via WSL2 (best-effort, takes 30–60 min)..."
	@echo "Server-tech: $(SERVER_TECH_REPO)@$(SERVER_TECH_REF)"
	wsl bash -c " \
	  set -e; cd $$(pwd) && \
	  bash tools/prepull-images.sh && \
	  if [ ! -d pi-gen ]; then git clone --depth=1 --branch arm64 https://github.com/RPi-Distro/pi-gen.git; fi && \
	  cp pi-gen.config pi-gen/config && \
	  rm -rf pi-gen/stage-streaming && cp -r stage-streaming pi-gen/stage-streaming && \
	  cd pi-gen && \
	  sudo --preserve-env=SERVER_TECH_REPO,SERVER_TECH_REF CLEAN=1 ./build-docker.sh && \
	  mkdir -p ../$(DEPLOY_DIR) && cp deploy/*.img.xz ../$(DEPLOY_DIR)/ && \
	  cd ../$(DEPLOY_DIR) && for f in *.img.xz; do sha256sum \"\$$f\" > \"\$$f.sha256\"; done \
	" SERVER_TECH_REPO=$(SERVER_TECH_REPO) SERVER_TECH_REF=$(SERVER_TECH_REF)

flash-prep:
	@echo ""
	@echo "===================================================="
	@echo " SD-CARD FLASH (Laufwerk G: ist die Ziel-SD)"
	@echo "===================================================="
	@echo ""
	@echo " 1. Raspberry Pi Imager öffnen (https://www.raspberrypi.com/software/)."
	@echo " 2. CHOOSE OS  →  Use custom  →  $(DEPLOY_DIR)/chaoscrew-streaming-*.img.xz"
	@echo " 3. CHOOSE STORAGE  →  Generic-SD-Card auf G: auswählen."
	@echo " 4. Strg+Shift+X für 'Erweitert':"
	@echo "      Hostname            : chaoscrew"
	@echo "      SSH                 : aktiviert (Public-Key oder Passwort)"
	@echo "      WLAN-SSID + Passwort: <dein Netz>"
	@echo "      Locale              : Europe/Berlin, Tastatur DE"
	@echo " 5. WRITE bestätigen, ~3 min auf SanDisk Extreme."
	@echo " 6. SD in Pi 4 stecken, USB-Strom + C920 anschließen, einschalten."
	@echo " 7. Nach 60–90 s:  ping chaoscrew.local"
	@echo " 8. Browser: http://chaoscrew.local"
	@echo ""
	@echo "Tipp: 'make verify' läuft sha256 gegen $(DEPLOY_DIR)/*.sha256 vor dem Flash."
	@echo ""

verify:
	@cd $(DEPLOY_DIR) && for f in *.sha256; do \
	  echo "Checking $$f..."; \
	  sha256sum -c $$f; \
	done

clean:
	rm -rf $(DEPLOY_DIR)/*

mediamtx-check:
	@echo "Verifying ffmpeg capabilities in bluenviron/mediamtx:1-ffmpeg-rpi (linux/arm64)..."
	@docker run --rm --platform linux/arm64 --entrypoint ffmpeg \
	  bluenviron/mediamtx:1-ffmpeg-rpi -hide_banner -encoders 2>&1 \
	  | grep -E '(h264_v4l2m2m|libx264)' \
	  || { echo "FAIL: no H.264 encoder (v4l2m2m or libx264)"; exit 1; }
	@docker run --rm --platform linux/arm64 --entrypoint ffmpeg \
	  bluenviron/mediamtx:1-ffmpeg-rpi -hide_banner -encoders 2>&1 \
	  | grep -E 'libopus' \
	  || { echo "FAIL: libopus (audio) missing"; exit 1; }
	@docker run --rm --platform linux/arm64 --entrypoint ffmpeg \
	  bluenviron/mediamtx:1-ffmpeg-rpi -hide_banner -demuxers 2>&1 \
	  | grep -E '\balsa\b' \
	  || { echo "FAIL: ALSA demuxer missing — audio capture won't work"; exit 1; }
	@echo "OK — H.264 encoder + Opus + ALSA all present"
