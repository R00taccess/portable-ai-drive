#!/usr/bin/env bash
# Portable AI Drive - Linux setup launcher
# https://github.com/R00taccess/portable-ai-drive
set -e
cd "$(dirname "$0")"
RAW="https://raw.githubusercontent.com/R00taccess/portable-ai-drive/main"
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is needed (sudo apt install python3  /  sudo dnf install python3)."
  exit 1
fi
if [ ! -f installer/setup.py ]; then
  echo "Downloading the installer from GitHub..."
  mkdir -p installer
  curl -fsSL -o installer/setup.py "$RAW/installer/setup.py"
  curl -fsSL -o installer/catalog.json "$RAW/installer/catalog.json"
fi
exec python3 installer/setup.py "$@"
