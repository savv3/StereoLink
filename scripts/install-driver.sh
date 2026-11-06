#!/bin/bash
# Installs (or with --uninstall, removes) the StereoLink virtual audio device.
# Needs admin rights; restarts coreaudiod, which briefly interrupts all audio.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Library/Audio/Plug-Ins/HAL/StereoLink.driver"

if [[ "${1:-}" == "--uninstall" ]]; then
    sudo rm -rf "$DEST"
else
    [[ -d build/StereoLink.driver ]] || scripts/build-driver.sh
    sudo rm -rf "$DEST"
    sudo cp -R build/StereoLink.driver "$DEST"
    sudo chown -R root:wheel "$DEST"
fi

sudo killall coreaudiod
echo "Done. Audio restarts in a few seconds."
