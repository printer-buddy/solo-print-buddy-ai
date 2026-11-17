#!/bin/sh
#LICENSE
#
#Copyright (C) 2026  sterling motuz <Sterling@dexabyte.ca>
#
#for https://github.com/printer-buddy/printer-buddy
#
#SPDX-License-Identifier: AGPL-3.0-only
#
#Additional term (AGPL-3.0 section 7b, keep author credit): keep this header
#
#Additional term (AGPL-3.0 section 7c, mark changed versions): if you make any changes, you must include a CHANGELOG with all changes and their dates
# Printer Buddy AI for a Klipper printer. Run on the printer:  sh install.sh
# Installs into /usr/data/printer-buddy-ai (or ~/printer-buddy-ai, or $PB_AI_DIR) and starts at boot.
set -e
REPO="https://github.com/printer-buddy/solo-print-buddy-ai.git"
REL="https://github.com/printer-buddy/printer-buddy/releases/download/ai-lite-v1.5"
if [ -n "$PB_AI_DIR" ]; then DIR="$PB_AI_DIR"
elif [ -d /usr/data ]; then DIR=/usr/data/printer-buddy-ai
else DIR="$HOME/printer-buddy-ai"; fi
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"
  else wget -q -O "$2" "$1"; fi
}

command -v git >/dev/null 2>&1 || { echo "git is needed."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed."; exit 1; }
python3 -c "import numpy, PIL" 2>/dev/null || { echo "This needs the Python packages numpy and Pillow (pip3 install numpy Pillow)."; exit 1; }

if [ ! -d "$DIR/.git" ]; then
  echo "Downloading to $DIR ..."
  TMP="$DIR.new"
  rm -rf "$TMP"
  git clone -q -b main "$REPO" "$TMP"
  for f in config.json model.json printer-buddy-lite.npz log.txt; do
    if [ -f "$DIR/$f" ]; then mv "$DIR/$f" "$TMP/$f"; fi
  done
  rm -rf "$DIR"
  mv "$TMP" "$DIR"
fi
fetch "$REL/model.json" "$DIR/model.json"
fetch "$REL/printer-buddy-lite.npz" "$DIR/printer-buddy-lite.npz"
[ -f "$DIR/config.json" ] || cat > "$DIR/config.json" <<'JSON'
{
  "moonraker": "http://127.0.0.1:7125",
  "camera_url": "",
  "interval": 30,
  "threshold": 0.6,
  "checks_in_a_row": 3,
  "pause": false,
  "card": true,
  "card_dir": ""
}
JSON

if [ -d /run/systemd/system ]; then
  $SUDO tee /etc/systemd/system/printer-buddy-ai.service >/dev/null <<UNIT
[Unit]
Description=Printer Buddy AI
After=network-online.target moonraker.service

[Service]
User=$(id -un)
WorkingDirectory=$DIR
ExecStart=$(command -v python3) $DIR/pb_ai.py
Restart=always
RestartSec=10
StandardOutput=append:$DIR/log.txt
StandardError=append:$DIR/log.txt

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable -q printer-buddy-ai
  $SUDO systemctl restart printer-buddy-ai
  echo "Started, and it will start at boot. Log: $DIR/log.txt"
elif [ -d /etc/init.d ]; then
  $SUDO tee /etc/init.d/S99printer_buddy_ai >/dev/null <<INIT
#!/bin/sh
case "\$1" in
  start) cd $DIR && nohup python3 pb_ai.py >> $DIR/log.txt 2>&1 & ;;
  stop) pkill -f "$DIR/pb_ai.py" 2>/dev/null; pkill -f "python3 pb_ai.py" 2>/dev/null ;;
  restart) \$0 stop; sleep 1; \$0 start ;;
esac
INIT
  $SUDO chmod +x /etc/init.d/S99printer_buddy_ai
  $SUDO /etc/init.d/S99printer_buddy_ai restart
  echo "Started, and it will start at boot. Log: $DIR/log.txt"
else
  echo "Installed. Start it with: cd $DIR && python3 pb_ai.py"
fi

MRCONF=""
for f in /usr/data/printer_data/config/moonraker.conf "$HOME/printer_data/config/moonraker.conf"; do
  if [ -f "$f" ]; then MRCONF="$f"; break; fi
done
if [ -n "$MRCONF" ] && ! grep -q '^\[update_manager printer-buddy-ai\]' "$MRCONF"; then
  cat >> "$MRCONF" <<CONF

[update_manager printer-buddy-ai]
type: git_repo
channel: stable
path: $DIR
origin: $REPO
primary_branch: main
is_system_service: False
CONF
  echo "Added Printer Buddy AI to Moonraker's update manager ($MRCONF). Restarting Moonraker..."
  if [ -d /run/systemd/system ]; then $SUDO systemctl restart moonraker
  elif [ -x /etc/init.d/S56moonraker_service ]; then /etc/init.d/S56moonraker_service restart
  else echo "Restart Moonraker yourself to load it."; fi
elif [ -z "$MRCONF" ]; then
  echo "moonraker.conf not found: add an [update_manager printer-buddy-ai] section yourself to get updates in Fluidd / Mainsail."
fi

add_camera() {
  PB_AI_DIR="$DIR" python3 - <<'PY'
import json, os, sys, urllib.request
try:
    base = json.load(open(os.path.join(os.environ["PB_AI_DIR"], "config.json"))).get("moonraker") or "http://127.0.0.1:7125"
except (OSError, ValueError):
    base = "http://127.0.0.1:7125"
name, url = "Printer Buddy AI", "/server/files/config/.printer-buddy-ai/status.svg"
cams = json.load(urllib.request.urlopen(base + "/server/webcams/list", timeout=10))["result"]["webcams"]
if any(c.get("name") == name for c in cams):
    print('A camera named "%s" is already there.' % name)
    sys.exit(0)
body = json.dumps({"name": name, "service": "mjpegstreamer-adaptive", "snapshot_url": url, "stream_url": url,
                   "target_fps": 1, "target_fps_idle": 1}).encode()
req = urllib.request.Request(base + "/server/webcams/item", data=body, headers={"Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=10).read()
print('Camera "%s" added.' % name)
PY
}

echo
printf "Add the status card as a camera in Fluidd / Mainsail? [y/N] "
ans=""
{ read -r ans < /dev/tty; } 2>/dev/null || ans=""
added=0
case "$ans" in
  y|Y|yes|Yes|YES) add_camera && added=1 || echo "Couldn't add the camera." ;;
  *) echo ;;
esac
if [ "$added" -eq 0 ]; then
  echo "To see the status card in Fluidd or Mainsail, add a camera (Settings > Cameras / Webcams):"
  echo "  Name:         Printer Buddy AI"
  echo "  Service:      MJPEG Adaptive"
  echo "  Snapshot URL: /server/files/config/.printer-buddy-ai/status.svg"
  echo "  Target FPS:   1"
fi
echo
echo "Settings: $DIR/config.json  (set \"pause\": true to pause the print on an alert)"
