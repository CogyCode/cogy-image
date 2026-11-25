#!/usr/bin/env bash
# Removes Cogy Image, as installed by install.sh.
#
# Always removes the systemd units (the image service, the model server and
# the firewall rules), the ufw rules install.sh added, and the NPU udev rule.
# Files (GenieX, the model, configuration, logs) and the service user are
# kept unless --remove-files is given, so a re-install does not download the
# model again.
# The machine stays on Cogy Server's private network (join-network.sh is a
# separate step); run "sudo tailscale logout" to leave it.
#
# Usage: ./uninstall.sh [--remove-files]
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
. "$REPO_DIR/lib/common.sh"

REMOVE_FILES=0
case "${1:-}" in
    '') ;;
    --remove-files) REMOVE_FILES=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1 (see --help)" ;;
esac
require_root "$@"

# Stopping through systemd sends GenieX SIGTERM and waits, so it releases the
# NPU's buffers.
for unit in "$SERVICE_NAME" "$MODEL_SERVICE_NAME" "$FIREWALL_SERVICE_NAME"; do
    if [ -f "$SYSTEMD_DIR/$unit.service" ]; then
        echo "Removing unit $unit"
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_DIR/$unit.service"
    fi
done
systemctl daemon-reload
nft delete table inet "$NFT_TABLE" 2>/dev/null || true

if command -v ufw >/dev/null 2>&1; then
    # Delete by number, highest first so the remaining numbers stay valid,
    # every rule commented with $NAME.
    for n in $(ufw status numbered 2>/dev/null | grep -F "# $NAME" | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn); do
        echo "Removing ufw rule $n"
        ufw --force delete "$n" >/dev/null
    done
fi

if [ -f "$UDEV_RULE" ]; then
    echo 'Removing NPU udev rule'
    rm -f "$UDEV_RULE"
    udevadm control --reload-rules
    for dev in /dev/fastrpc-* /dev/dma_heap/*; do
        [ -e "$dev" ] && setfacl -x "u:$SERVICE_USER" "$dev" 2>/dev/null || true
    done
fi

if [ "$REMOVE_FILES" -eq 1 ]; then
    for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"; do
        if [ -d "$dir" ]; then
            echo "Deleting $dir"
            rm -rf --one-file-system "$dir"
        fi
    done
    if id "$SERVICE_USER" >/dev/null 2>&1; then
        echo "Removing user $SERVICE_USER"
        userdel "$SERVICE_USER"
    fi
fi

printf '\033[32m%s uninstalled.\033[0m\n' "$NAME"
