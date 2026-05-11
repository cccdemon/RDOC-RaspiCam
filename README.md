# RaspiImage — Pi 4 streaming SD-Card-Image

Pi-OS-Lite-basiertes Image für Raspberry Pi 4, das nach erstem Boot von alleine einen WebRTC-Stream der angeschlossenen Logitech-C920-Kamera serviert. Image wird via GitHub Actions in der Cloud gebaut.

## Quick Start (empfohlen: Stock-Image + Setup-Script)

```bash
# 1. Raspberry Pi OS Lite 64-bit mit Raspberry Pi Imager flashen
#    Hostname: chaoscrew, SSH aktivieren, WLAN setzen

# 2. Pi booten, per SSH verbinden
ssh streamer@chaoscrew.local

# 3. Setup-Repo klonen und Installer starten
git clone https://github.com/cccdemon/RDOC-RaspiCam.git
cd RDOC-RaspiCam
sudo scripts/install-on-pi.sh

# 4. Browser
# http://chaoscrew.local
```

Der Installer macht den bisherigen Image-Build zur Laufzeit auf dem Pi: Docker installieren, `cccdemon/homecam-docker` nach `/opt/server-tech` klonen, Pi-Overrides kopieren, MediaMTX+ffmpeg-Container bauen, systemd/udev/avahi/watchdog konfigurieren und den Stream starten.

Optional:

```bash
SERVER_TECH_REPO=cccdemon/homecam-docker SERVER_TECH_REF=main sudo -E scripts/install-on-pi.sh
```

Public TLS via Cloudflare DNS-Challenge:

```bash
sudo nano /opt/server-tech/.env
# set:
# PUBLIC_HOSTNAME=stream.example.org
# PUBLIC_EMAIL=admin@example.org
# CLOUDFLARE_API_TOKEN=<token with Zone.DNS:Edit>

sudo systemctl restart chaoscrew-streaming
```

The installer builds a local Caddy image with the Cloudflare DNS plugin. DNS-01 does not require port 80 for certificate issuance; expose/forward 443 for browser access.

## Quick Start (Legacy: eigenes Image bauen)

```powershell
# 1. Image bauen (auf GitHub Actions, ~25 min)
make image

# 2. Flash-Anleitung (SD-Karte ist auf Laufwerk G:)
make flash-prep

# 3. Pi 4 booten, mit C920 verbunden
ping chaoscrew.local
# Browser: http://chaoscrew.local
```

## Voraussetzungen

- **Build**: GitHub-Account + `gh` CLI eingerichtet (oder WSL2 für lokale Fallback-Builds)
- **Hardware**: Raspberry Pi 4 (4 oder 8 GB), aktiver Lüfter empfohlen, Logitech C920, mind. 16 GB SD-Karte (Class A1 oder besser)
- **Tooling auf dem Build-Host**: `gh`, `make`, optional `wsl`

## Was bekommt man?

Ein bootbares `.img.xz`-File (~ 800 MB komprimiert, ~ 3 GB entpackt) das:

- **Pi OS Lite Bookworm 64-bit** als Basis
- Hostname `chaoscrew`, SSH aktiviert (Konfig kommt vom RPi-Imager-Preconfig-Step)
- avahi/mDNS broadcastet `chaoscrew.local`
- Docker + Docker-Compose vorinstalliert
- Server-Tech als **echtes Git-Working-Tree** in `/opt/server-tech` (geclont während Build aus `cccdemon/homecam-docker`, Default-Ref `main`) — Updates via `cd /opt/server-tech && git pull && sudo systemctl restart chaoscrew-streaming`
- Pi-spezifischer ffmpeg-Pfad (Hardware-Encoder `h264_v4l2m2m`, 1920x1080@30, ~8 Mbps) in `mediamtx.pi.template.yml`
- Audio-Capture vom USB-Kamera-Mikro (C920 Stereo) als Opus 96k — Default an, toggle via `AUDIO_ENABLED` in `.env`
- Docker-Images **vorgepullt** im Image — kein 5-Min-Wait beim Erstboot
- systemd-Service `chaoscrew-streaming.service` läuft beim Boot automatisch hoch
- udev-Regel: bei C920-(Wieder)-Anstecken neustart des Streams
- tmpfs für `/var/log` (via fstab), ext4 commit=600 — schont die SD
- Hardware-Watchdog (BCM2835) aktiviert, Reboot bei Hang nach 15 s
- Optional: Caddy-Container mit Auto-TLS via `.env` `PUBLIC_HOSTNAME=`

## Workflow im Detail

### 1. Image bauen — primärer Pfad: GitHub Actions

`make image`:
1. Triggert das Workflow `.github/workflows/build-image.yml` auf `main`.
2. Workflow läuft auf `ubuntu-24.04`, klont pi-gen, kopiert unsere `stage-streaming/` rein, baut.
3. Im Build-Stage 20 macht der pi-gen-chroot ein `git clone --depth=1 --branch=$SERVER_TECH_REF` von `cccdemon/homecam-docker` direkt nach `/opt/server-tech`. Standard-Ref: `main`. Über die Workflow-Inputs `server_tech_repo` / `server_tech_ref` kannst du beim manuellen Trigger auf einen Tag oder SHA pinnen.
4. Output: `chaoscrew-streaming-YYYYMMDD.img.xz` + `.sha256` als Artifact.
5. `gh run download` zieht das Artifact ins lokale `deploy/`.

Build-Zeit auf GH-Actions-`ubuntu-24.04`: ~ 20–25 min (das meiste ist `apt` und `docker pull`).

**Update-Workflow ohne Image-Reflash**: Da `/opt/server-tech` ein echtes Git-Working-Tree ist, kannst du auf dem Pi:
```bash
ssh streamer@chaoscrew.local
cd /opt/server-tech && git pull
sudo systemctl restart chaoscrew-streaming
```
Bei Konflikten mit unseren Pi-Overrides (`compose.override.yml`, `mediamtx.pi.template.yml`, `Caddyfile`, `.env`, `start-streaming.sh`) ggf. `git stash` davor — die Pi-Files sind nicht im Server-tech-Repo getrackt, dürfen also nebeneinander leben.

### 2. Image bauen — Fallback: WSL2 lokal

`make image-local SERVER_TECH_REPO=raumdock/Server-tech SERVER_TECH_REF=main`:
1. Klont pi-gen ins lokale `pi-gen/`.
2. Pre-pullt die ARM64-Docker-Images via `tools/prepull-images.sh`.
3. Ruft `pi-gen/build-docker.sh` aus WSL2 mit `SERVER_TECH_REPO`/`SERVER_TECH_REF` als Env.
4. Output landet in `pi-gen/deploy/`, wird nach `deploy/` kopiert.

Funktioniert oft, **bricht manchmal** (binfmt-Flakiness, chroot, CRLF). Wenn der WSL-Build streikt, GH Actions nutzen.

### 3. SD-Karte flashen

`make flash-prep` druckt die Schritt-für-Schritt-Anleitung. Kurzform:

1. **Raspberry Pi Imager** öffnen (nicht balena-Etcher!) — der Imager kann WiFi/SSH/User direkt im Boot-FAT-Volume hinterlegen.
2. **CHOOSE OS** → "Use custom" → das `.img.xz` aus `deploy/`.
3. **CHOOSE STORAGE** → die SD auf Laufwerk **G:**.
4. **Strg+Shift+X** für Erweitert: Hostname, SSH, WiFi, Locale.
5. **WRITE**.

### 4. Erstboot

1. SD in Pi 4, USB-C-Power, C920 angeschlossen, ggf. Ethernet.
2. Grüne LED blinkt initial, geht nach 60–90 s in Dauer-grün — Boot komplett.
3. Aus Windows: `ping chaoscrew.local` antwortet.
4. Browser: `http://chaoscrew.local` → Stream-UI lädt, WebRTC verbindet binnen ~3 s.

### 5. Verifikation nach erstem Boot

```bash
ssh streamer@chaoscrew.local
systemctl status chaoscrew-streaming
docker compose -f /opt/server-tech/docker-compose.yml -f /opt/server-tech/compose.override.yml ps
v4l2-ctl --list-devices
```

Erwartet: Service `active (running)`, beide Container `healthy`, C920 in der V4L2-Liste.

## Optionaler Public-Access (Caddy)

`/opt/server-tech/.env` editieren:
```
PUBLIC_HOSTNAME=stream.example.org
PUBLIC_EMAIL=admin@example.org
```

DNS-A-Record auf eure öffentliche IP, Port 80/443 forwardet auf den Pi, dann:
```bash
sudo systemctl restart chaoscrew-streaming
```

Caddy holt Let's-Encrypt-Cert automatisch (HTTP-01-Challenge), Stream ist von außen via `https://stream.example.org` erreichbar.

## Encoder: h264_v4l2m2m bei 1080p@30 (Default)

Pi 4 hat einen Hardware-H.264-Encoder (BCM2711 V4L2 M2M). Default-Config nutzt ihn für 1920x1080@30 bei ~8 Mbps:

- **CPU**: ~15-25 % auf einem Core. Bleibt unter Throttle-Schwelle, aber **aktive Kühlung ist trotzdem dringend empfohlen** für stundenlanges Streaming.
- **Profil**: `constrained_baseline`. WebRTC-kompatibel, in jedem Browser. High-Profile ist auf v4l2m2m unzuverlässig — nicht ändern.
- **Keine B-Frames** (`-bf 0`): Encoder unterstützt sie nicht.
- **CBR statt CRF**: v4l2m2m kann nur Bitrate-basiert, kein CRF. `-b:v 8M -maxrate 8M`.

### Bekannte Quirks von v4l2m2m auf Pi 4

- Gelegentliches **Banding** auf flächigen Farben (graue Wand, blauer Himmel)
- Sporadische **GOP-Glitches** bei abrupten Bewegungen
- Pi-Foundation hat den Encoder als "deprecated" markiert — wird aber im Pi-OS-64-Kernel 6.x weiter ausgeliefert.

Für LAN-Live-Streaming akzeptabel. Für Studio-Recording → drop zu Software-libx264 (siehe Fallback unten).

## Audio (Kamera-Mikro)

Default: **an**, Codec **Opus 96k Stereo**, gecaptured von der ALSA-Karte der Kamera.

**Warum Opus statt AAC**: WebRTC kann nativ Opus → kein Transcode-Hop in MediaMTX (was sonst CPU kosten würde). Opus läuft auch in HLS-fmp4 und allen modernen Browsern.

**Detection** in `start-streaming.sh prepare`:
```bash
arecord -l | grep "HD Pro Webcam C920"   # exact match
arecord -l | grep "USB"                   # fallback: any USB capture
```
Findet's nichts trotz `AUDIO_ENABLED=true` → Warning im Log, Stream läuft Video-only weiter.

**Toggle**:
```bash
ssh streamer@chaoscrew.local
sudo sed -i 's/^AUDIO_ENABLED=.*/AUDIO_ENABLED=false/' /opt/server-tech/.env
sudo systemctl restart chaoscrew-streaming
```

**Latenz**: Opus-Encoding fügt ~5-20 ms zur Audio-Pipeline. WebRTC-Total-Latenz bleibt unter 1 s.

**Container-Anforderung**: `/dev/snd` ist im `compose.override.yml` als Device-Passthrough deklariert. Wenn du den Stack händisch ohne Override startest, fehlt Audio.

### Software-Fallback (wenn HW-Artefakte stören oder du auf 720p willst)

`/opt/server-tech/mediamtx.pi.template.yml` editieren — am Ende ist der libx264-ultrafast-Block auskommentiert (720p@30, ~4 Mbps, ~50 % CPU). Den oberen v4l2m2m-Block auskommentieren, den unteren aktivieren, dann:
```bash
sudo systemctl restart chaoscrew-streaming
```

Optional kannst du auch die `/dev/video10..13` Passthroughs in `compose.override.yml` rauskommentieren — sie sind im Software-Modus nicht nötig.

## Troubleshooting

| Symptom | Schau hier nach |
|---|---|
| `chaoscrew.local` nicht erreichbar | Pi mit Ethernet-Kabel an Router stecken; mDNS auf manchen Switches deaktiviert. `arp -a` → Pi-IP finden. |
| `chaoscrew-streaming` startet nicht | `journalctl -u chaoscrew-streaming -f` |
| Kamera nicht erkannt | `lsusb \| grep 046d:082d`, `v4l2-ctl --list-devices`. C920 USB-Kabel direkt am Pi (nicht über Hub). |
| Stream stottert / Encoder-Fehler im Log | `vcgencmd measure_temp` — sollte unter 70 °C bleiben. Active-Cooling-Lüfter dazu. Falls trotzdem Glitches: auf Software-libx264-Fallback wechseln (siehe unten). |
| ffmpeg meldet "Cannot open V4L2 M2M codec" | Kernel-Modul `bcm2835-codec` fehlt oder ist disabled. `lsmod \| grep bcm2835_codec`. Ist ab Bookworm Default aktiv. Wenn weg, im RaspiImage neu bauen. |
| Encoder-Banding auf einfarbigen Flächen | v4l2m2m-Eigenheit. Bitrate auf 12 Mbps anheben (`mediamtx.pi.yml` `-b:v 12M`) oder Software-Fallback nutzen. |
| Kein Audio im Browser, obwohl AUDIO_ENABLED=true | `journalctl -u chaoscrew-streaming \| grep Audio`. Wahrscheinlich keine ALSA-Karte gefunden — `arecord -l` ssh'en und checken. C920 muss vor Service-Start eingesteckt sein, sonst greift die udev-Rebind-Regel. |
| Audio asynchron zum Video | `mediamtx.pi.yml` `runOnInit:` editieren, `-itsoffset 0.2` (Audio 200 ms verzögert) bzw. `-itsoffset -0.2` (Video verzögern). USB-Bus-Sync-Drift ist Hardware-abhängig. |
| Watchdog rebootet ständig | `journalctl -k \| grep -i watchdog`. Normalerweise heißt das: Service hängt. `systemctl disable streaming.watchdog` als Notfall. |
| Caddy bekommt kein Cert | Port 80 erreichbar von außen? `curl -vI http://<public-ip>` aus dem Internet. ACME-Email gesetzt? |

## Verzeichnisstruktur

```
RaspiImage/
├── Makefile                      # Build + Flash-Helper
├── README.md                     # diese Datei
├── pi-gen.config                 # pi-gen top-level config + SERVER_TECH_REPO/REF
├── .github/workflows/
│   └── build-image.yml           # GH Actions pi-gen build
├── tools/
│   └── prepull-images.sh         # docker pull ARM64 images → save to images.tar
├── stage-streaming/              # custom pi-gen stage on top of stage2 Lite
│   ├── prerun.sh
│   ├── EXPORT_IMAGE              # marks this stage as image-producing
│   ├── 00-install-system/        # apt packages (incl. git, alsa-utils), avahi, systemd, udev, motd
│   ├── 10-install-docker/        # Docker + Compose plugin
│   ├── 20-install-streaming/     # git-clone Server-tech in chroot + Pi-Overrides
│   └── 30-finalize/              # commit=600, watchdog, swap-off, BT/UART aus
└── deploy/                       # Build-Output (gitignored)
```

## Lizenz

AGPL-3.0-or-later. Server-Tech-Snapshot folgt der Server-Tech-Lizenz.
