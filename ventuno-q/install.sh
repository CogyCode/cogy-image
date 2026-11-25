#!/usr/bin/env bash
# Installs Cogy Image on an Arduino VENTUNO Q (Qualcomm Dragonwing IQ8,
# QCS8275): Qwen3-VL-4B-Instruct on the NPU through GenieX, behind a small
# service on this machine's private network address, started at boot and
# restarted on a crash. Names, ports and model: config/settings.env.
#
# Run join-network.sh first: this machine must be on Cogy Server's private
# network. Safe to re-run; each step is skipped when already done.
#   1. System packages (Python 3, nftables, ACL tools) and the NPU driver check
#   2. Service user, directories and access to the NPU's devices
#   3. GenieX (pinned version, SHA-256 checked)
#   4. Model download (pinned, SHA-256 checked) and import into GenieX
#   5. Check: this machine is on Cogy Server's private network
#   6. Firewall: the API port is reachable only from ALLOW_FROM
#   7. The image service (image/*.py) and its configuration
#   8. systemd units: the model server on 127.0.0.1, the image service on
#      the private address; start at boot, restart on failure
#   9. Self-test: /health, POST /inspect with a generated screenshot, OpenAI
#      passthrough
#
# Usage: ./install.sh
set -euo pipefail
# Under pipefail, a pipeline whose reader exits early (grep -q, head, awk
# exit) fails intermittently when the writer gets SIGPIPE. Readers here
# consume their whole input: grep >/dev/null, sed -n 1p, awk with a flag.

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
. "$REPO_DIR/lib/common.sh"
[ -n "${ALLOW_FROM// /}" ] || fail "ALLOW_FROM is empty: set it to Cogy Server's private address in config/settings.env, then re-run."

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = aarch64 ] ||
    fail "This build runs on Linux ARM64 (the VENTUNO Q); this is $(uname -s) $(uname -m)"

# Joining the private network is a separate step (join-network.sh).
if [ -z "$(private_ip)" ]; then
    fail "This machine is not on Cogy Server's private network. Run join-network.sh first:
    ./join-network.sh --login-server http://<server-ip>:8780"
fi

require_root "$@"

mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_DIR/install.log") 2>&1

GENIEX_DIR="$INSTALL_DIR/geniex"
DOWNLOAD_DIR="$STATE_DIR/download"
# Disk space the model needs in STATE_DIR while it is downloaded and imported.
MIN_FREE_GB=8

# Runs GenieX as the service user, with its model store in STATE_DIR.
geniex_as_user() {
    runuser -u "$SERVICE_USER" -- env HOME="$STATE_DIR" LD_LIBRARY_PATH="$GENIEX_DIR" \
        "$GENIEX_DIR/geniex" "$@" </dev/null
}

trap 'printf "\n\033[31mINSTALL FAILED (line %s). Log: %s\033[0m\n" "$LINENO" "$LOG_DIR/install.log" >&2' ERR

step "Install directories $INSTALL_DIR, $CONFIG_DIR, $STATE_DIR"

# Stop the services before replacing their files, whatever their state: a
# model server retrying its warm-up is "activating", not "active", and keeps
# the GenieX libraries loaded.
for unit in "$SERVICE_NAME" "$MODEL_SERVICE_NAME"; do
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    case "$state" in
        inactive|failed|unknown|'') ;;
        *)
            info "Stopping $unit ($state)"
            systemctl stop "$unit"
            ;;
    esac
done

# --- 1. System packages and the NPU driver -------------------------------------
step 'System packages'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 nftables acl curl ca-certificates libatomic1 libglib2.0-0 >/dev/null
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || fail "Python 3.10 or later needed: $(python3 --version)"
info "$(python3 --version), $(nft --version)"

step 'NPU (Hexagon v75 through FastRPC)'
machine=$(tr -d '\0' </sys/devices/soc0/machine 2>/dev/null || true)
board=$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)
info "SoC: ${machine:-unknown}; board: ${board:-unknown}"
case "$machine $board" in
    *8275*|*IQ8*|*IQ-8*|*VENTUNO*|*Ventuno*) ;;
    *) info "WARNING: this does not look like a $MODEL_CHIPSET. The model is compiled for the $MODEL_CHIPSET's NPU and may not load." ;;
esac
if ! ldconfig -p | grep 'libcdsprpc\.so' >/dev/null; then
    info 'FastRPC library (libcdsprpc) missing; installing the Qualcomm driver packages'
    apt-get install -y -qq qcom-fastrpc1 qcom-adreno1 >/dev/null 2>&1 ||
        fail "Could not install qcom-fastrpc1 and qcom-adreno1. They come from Qualcomm's PPA
(ppa:ubuntu-qcom-iot/qcom-ppa), which the board's Ubuntu image normally has.
Add it with: sudo add-apt-repository ppa:ubuntu-qcom-iot/qcom-ppa, then re-run."
fi
npu_devices=$(ls /dev/fastrpc-cdsp* 2>/dev/null || true)
[ -n "$npu_devices" ] || fail 'No NPU device (/dev/fastrpc-cdsp*): the FastRPC driver is not loaded'
info "Devices: $(echo $npu_devices $(ls /dev/dma_heap/* 2>/dev/null) | tr '\n' ' ')"

# --- 2. Service user, directories, NPU access -----------------------------------
step "Service user $SERVICE_USER"
if id "$SERVICE_USER" >/dev/null 2>&1; then
    info 'Already exists'
else
    useradd --system --user-group --home-dir "$STATE_DIR" --no-create-home \
        --shell /usr/sbin/nologin --comment "$NAME" "$SERVICE_USER"
    info 'Created'
fi
install -d -m 0755 -o root -g root "$INSTALL_DIR"
install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR" "$LOG_DIR"
install -d -m 0700 -o root -g root "$DOWNLOAD_DIR"

# The model server runs as the service user and needs read/write access to
# the NPU's devices. Where a device's group has that access, the user joins
# the group; otherwise the user gets an ACL entry, reapplied at boot by udev.
step 'NPU device access'
NPU_GROUPS=''
acl_needed=0
for dev in $npu_devices /dev/dma_heap/*; do
    [ -e "$dev" ] || continue
    if runuser -u "$SERVICE_USER" -- test -r "$dev" -a -w "$dev"; then continue; fi
    group=$(stat -c %G "$dev")
    mode=$(stat -c %a "$dev")
    if [ "$group" != root ] && [ $(( 0${mode: -2:1} & 6 )) -eq 6 ]; then
        case " $NPU_GROUPS " in *" $group "*) ;; *) NPU_GROUPS="${NPU_GROUPS:+$NPU_GROUPS }$group" ;; esac
    else
        acl_needed=1
        setfacl -m "u:$SERVICE_USER:rw" "$dev"
    fi
done
if [ "$acl_needed" -eq 1 ]; then
    cat >"$UDEV_RULE" <<EOF
# $NAME: lets $SERVICE_USER use the NPU (FastRPC and DMA heap devices).
KERNEL=="fastrpc-*", RUN+="/usr/bin/setfacl -m u:$SERVICE_USER:rw /dev/%k"
SUBSYSTEM=="dma_heap", RUN+="/usr/bin/setfacl -m u:$SERVICE_USER:rw /dev/dma_heap/%k"
EOF
    udevadm control --reload-rules
    info "ACL entries added; udev rule $UDEV_RULE keeps them across reboots"
elif [ -f "$UDEV_RULE" ]; then
    rm -f "$UDEV_RULE"
    udevadm control --reload-rules
fi
[ -n "$NPU_GROUPS" ] && info "Supplementary groups: $NPU_GROUPS"
for dev in $npu_devices; do
    if ! runuser -u "$SERVICE_USER" -g "$SERVICE_USER" ${NPU_GROUPS:+$(printf -- '-G %s ' $NPU_GROUPS)} -- test -r "$dev" -a -w "$dev"; then
        fail "$SERVICE_USER cannot open $dev ($(stat -c '%U:%G %a' "$dev"))"
    fi
done
info "$SERVICE_USER can use the NPU"

# --- 3. GenieX --------------------------------------------------------------------
step "GenieX $GENIEX_VERSION"
if [ -x "$GENIEX_DIR/geniex" ] && [ "$(cat "$GENIEX_DIR/geniex-version.txt" 2>/dev/null)" = "$GENIEX_VERSION" ]; then
    info 'Already installed'
else
    tarball="$DOWNLOAD_DIR/$(basename "$GENIEX_URL")"
    get_verified "$GENIEX_URL" "$GENIEX_SHA256" "$tarball"
    rm -rf "$GENIEX_DIR.new"
    mkdir -p "$GENIEX_DIR.new"
    tar -xzf "$tarball" -C "$GENIEX_DIR.new" --strip-components=1 --no-same-owner
    [ -f "$GENIEX_DIR.new/geniex" ] || fail "$(basename "$tarball") has no geniex binary"
    [ -f "$GENIEX_DIR.new/qairt/libgeniex_vlm.so" ] || fail "$(basename "$tarball") has no QAIRT vision plugin"
    chmod 0755 "$GENIEX_DIR.new/geniex"
    echo "$GENIEX_VERSION" >"$GENIEX_DIR.new/geniex-version.txt"
    rm -rf "$GENIEX_DIR"
    mv "$GENIEX_DIR.new" "$GENIEX_DIR"
    rm -f "$tarball"
fi
# The bundled QNN HTP stub loads libcdsprpc.so by its bare name, with only
# its own directory to look in: link the system's FastRPC libraries there.
for bare in libcdsprpc.so libadsprpc.so; do
    real=$(ldconfig -p | awk -v n="$bare" '!found && $1 ~ "^"n"(\\.|$)" { sub(/.*=> /, ""); print; found = 1 }')
    if [ -n "$real" ]; then ln -sfn "$real" "$GENIEX_DIR/$bare"; fi
done
[ -e "$GENIEX_DIR/libcdsprpc.so" ] || fail 'libcdsprpc.so not found: install qcom-fastrpc1'
info "$(geniex_as_user version 2>/dev/null | sed -n 1p || echo "geniex $GENIEX_VERSION")"

# --- 4. Model -----------------------------------------------------------------------
# The AI Hub bundle is downloaded, checked against its SHA-256, imported into
# GenieX's model store and deleted. model-sha256.txt records which bundle the
# store holds, so a re-run does not download it again.
step "Model $MODEL_NAME"
marker="$STATE_DIR/model-sha256.txt"
if [ "$(cat "$marker" 2>/dev/null)" = "$MODEL_SHA256" ] && geniex_as_user list --format json 2>/dev/null | grep -iF "\"$MODEL_NAME" >/dev/null; then
    info 'Already imported'
else
    zip="$DOWNLOAD_DIR/$(basename "$MODEL_URL")"
    free_gb=$(df --output=avail -BG "$STATE_DIR" | tail -n1 | tr -dc 0-9)
    [ "$free_gb" -ge "$MIN_FREE_GB" ] ||
        fail "Not enough disk: ${free_gb} GB free in $STATE_DIR, about $MIN_FREE_GB GB needed (download and import)"
    get_verified "$MODEL_URL" "$MODEL_SHA256" "$zip"
    chmod 0644 "$zip"
    chmod 0711 "$DOWNLOAD_DIR"
    # Only this model is kept: remove any others to free disk.
    geniex_as_user clean -y >/dev/null 2>&1 || true
    rm -f "$marker"
    info 'Importing into GenieX (a few minutes)...'
    geniex_as_user pull "$MODEL_NAME" --model-hub localfs --local-path "$zip" --model-type vlm
    geniex_as_user list --format json | grep -iF "\"$MODEL_NAME" >/dev/null || fail "Import of $MODEL_NAME failed: not in geniex list"
    echo "$MODEL_SHA256" >"$marker"
    chmod 0700 "$DOWNLOAD_DIR"
    rm -f "$zip"
fi
info "On disk: $(du -sh "$STATE_DIR/.cache/geniex" 2>/dev/null | cut -f1 || echo unknown)"

# --- 5. Private network ---------------------------------------------------------
step "Cogy Server's private network"
PRIVATE_IP=$(private_ip)
[ -n "$PRIVATE_IP" ] || fail 'This machine is not on the private network; run join-network.sh first'
info "Private address: $PRIVATE_IP"

# --- 6. Firewall --------------------------------------------------------------------
step "Firewall: port $PORT from $ALLOW_FROM only"
NFT=$(command -v nft)
ALLOW_ELEMENTS=$(echo "$ALLOW_FROM" | xargs | sed 's/ /, /g')
render "$REPO_DIR/config/firewall.nft" "$CONFIG_DIR/firewall.nft"
"$NFT" -c -f "$CONFIG_DIR/firewall.nft" || fail 'firewall.nft does not parse'
render "$REPO_DIR/config/$FIREWALL_SERVICE_NAME.service" "$SYSTEMD_DIR/$FIREWALL_SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$FIREWALL_SERVICE_NAME" >/dev/null 2>&1
systemctl restart "$FIREWALL_SERVICE_NAME"
info "nftables table inet $NFT_TABLE loaded"
# ufw, when active, drops what it does not allow, whatever this table accepts.
if command -v ufw >/dev/null 2>&1 && ufw status | grep '^Status: active' >/dev/null; then
    for src in $ALLOW_FROM; do
        ufw allow proto tcp from "$src" to any port "$PORT" comment "$NAME" >/dev/null
    done
    info "ufw is active: allowed port $PORT from $ALLOW_FROM"
fi

# --- 7. The image service -----------------------------------------------------------
step "$NAME service code"
install -d -m 0755 "$INSTALL_DIR/image"
# Every module of the service; the unit tests stay in the repository.
for py in "$REPO_DIR"/image/*.py; do
    case "$(basename "$py")" in test_*) continue ;; esac
    install -m 0644 "$py" "$INSTALL_DIR/image/"
done
install -m 0644 "$REPO_DIR/config/inspect-prompt.txt" "$INSTALL_DIR/image/"
SERVICE_CONFIG="$CONFIG_DIR/image.json"
python3 - "$SERVICE_CONFIG" <<PY
import json, sys
cfg = {
    "bind": "$PRIVATE_IP",
    "port": $PORT,
    "upstream": "http://127.0.0.1:$MODEL_PORT",
    "model": "$MODEL_NAME",
    "prompt_file": "$INSTALL_DIR/image/inspect-prompt.txt",
    "max_tokens": $MAX_TOKENS,
    "max_image_bytes": $MAX_IMAGE_BYTES,
    "timeout": $REQUEST_TIMEOUT,
    "log_file": "$LOG_DIR/image.log",
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PY
chown root:"$SERVICE_USER" "$SERVICE_CONFIG"
chmod 0640 "$SERVICE_CONFIG"
info "Installed to $INSTALL_DIR/image; configuration $SERVICE_CONFIG"

# --- 8. systemd units -------------------------------------------------------------
step "systemd unit $MODEL_SERVICE_NAME (model server, 127.0.0.1:$MODEL_PORT)"
render "$REPO_DIR/config/$MODEL_SERVICE_NAME.service" "$SYSTEMD_DIR/$MODEL_SERVICE_NAME.service"
render "$REPO_DIR/config/$SERVICE_NAME.service" "$SYSTEMD_DIR/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$MODEL_SERVICE_NAME" "$SERVICE_NAME" >/dev/null 2>&1
info 'Starting; the first start loads the model onto the NPU (a minute or two)...'
systemctl start "$MODEL_SERVICE_NAME" ||
    fail "$MODEL_SERVICE_NAME did not start; see: journalctl -u $MODEL_SERVICE_NAME"
info 'Started, model loaded'

step "systemd unit $SERVICE_NAME ($NAME, http://$PRIVATE_IP:$PORT)"
systemctl start "$SERVICE_NAME"
info 'Started'

# --- 9. Self-test -------------------------------------------------------------------
step 'Self-test'
trap - ERR
python3 "$REPO_DIR/scripts/verify.py" --self-test ||
    fail "Self-test failed; see $LOG_DIR/image.log and journalctl -u $MODEL_SERVICE_NAME"

base="http://$PRIVATE_IP:$PORT"
printf '\n\033[32m%s is installed.\033[0m\n' "$NAME"
echo "  Inspect: POST $base/inspect   {\"image\": \"<base64>\", \"caption\": \"...\"}"
echo "  Health:  GET  $base/health"
echo "  OpenAI:  POST $base/v1/chat/completions, GET $base/v1/models"
echo "  Model:   $MODEL_NAME  (context $CONTEXT_LENGTH, images ${IMAGE_SIZE} x ${IMAGE_SIZE})"
echo "  Logs:    $LOG_DIR, journalctl -u $MODEL_SERVICE_NAME"
