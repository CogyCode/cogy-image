#!/usr/bin/env bash
# Adds this machine to Cogy Server's private network. Run it before install.sh.
#
# Installs Tailscale if it is missing (from Tailscale's signed apt repository,
# after checking the signing key's fingerprint) and joins Cogy Server's network
# with a join key. Does nothing when the machine is already on the network,
# so it is safe to run again.
#
# Usage:
#   ./join-network.sh --login-server http://<server-ip>:8780 [--auth-key <key>]
#
#   --login-server  Cogy Server's network control URL. Use an IP address, not a
#                   .local name.
#   --auth-key      Join key from Cogy Server > Machines > Add a machine to the
#                   network. Asked for when not given, so it need not be typed
#                   on the command line or kept in the shell history.
#
# The join key is passed to Tailscale in a file, never on a command line,
# and is never written to the log.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
. "$REPO_DIR/lib/common.sh"

LOGIN_SERVER=''
AUTH_KEY=''
while [ $# -gt 0 ]; do
    case "$1" in
        --login-server) LOGIN_SERVER=${2:?}; shift 2 ;;
        --auth-key) AUTH_KEY=${2:?}; shift 2 ;;
        # Internal: the key is handed to the root instance in a file, so it
        # is never on sudo's command line.
        --auth-key-file) AUTH_KEY=$(cat "${2:?}"); rm -f "$2"; shift 2 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
done

# Already on the network: nothing to do (no root needed to check).
ip=$(private_ip)
if [ -n "$ip" ] && [ -z "$LOGIN_SERVER" ]; then
    echo "This machine is already on Cogy Server's private network: $ip"
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo 'Root rights needed; re-running with sudo...'
    args=()
    [ -n "$LOGIN_SERVER" ] && args+=(--login-server "$LOGIN_SERVER")
    if [ -n "$AUTH_KEY" ]; then
        key_file=$(mktemp)
        chmod 600 "$key_file"
        printf '%s' "$AUTH_KEY" > "$key_file"
        args+=(--auth-key-file "$key_file")
    fi
    status=0
    sudo -- bash "$0" "${args[@]}" || status=$?
    [ -n "${key_file:-}" ] && rm -f "$key_file"
    exit "$status"
fi

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/join-network.log"
KEY_FILE=''
cleanup() {
    [ -n "$KEY_FILE" ] && rm -f "$KEY_FILE"
    # Never leave the join key in the log.
    if [ -n "$AUTH_KEY" ] && [ -f "$LOG" ] && grep -qF -- "$AUTH_KEY" "$LOG"; then
        python3 - "$LOG" "$AUTH_KEY" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
open(path, "w", encoding="utf-8").write(text.replace(key, "<join key>"))
PY
    fi
}
trap cleanup EXIT
exec > >(tee "$LOG") 2>&1

step 'Tailscale'
if command -v tailscale >/dev/null 2>&1; then
    info "Already installed: $(tailscale version | sed -n 1p)"
else
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *) fail "Unsupported OS '${ID:-unknown}': install Tailscale by hand, then re-run" ;;
    esac
    codename=${VERSION_CODENAME:?no VERSION_CODENAME in /etc/os-release}
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg >/dev/null
    keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
    tmpkey=$(mktemp)
    curl -fsSL "$TAILSCALE_REPO/$ID/$codename.noarmor.gpg" -o "$tmpkey"
    fpr=$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '!found && $1 == "fpr" { print $10; found = 1 }')
    if [ "$fpr" != "$TAILSCALE_KEY_FINGERPRINT" ]; then
        rm -f "$tmpkey"
        fail "Tailscale signing key fingerprint check failed: got '$fpr', expected $TAILSCALE_KEY_FINGERPRINT"
    fi
    install -m 0644 "$tmpkey" "$keyring"
    rm -f "$tmpkey"
    info "Signing key $fpr OK"
    echo "deb [signed-by=$keyring] $TAILSCALE_REPO/$ID $codename main" > /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    apt-get install -y -qq tailscale >/dev/null
    info "Installed: $(tailscale version | sed -n 1p)"
fi
systemctl enable --now tailscaled >/dev/null 2>&1
for _ in $(seq 30); do [ -S /run/tailscale/tailscaled.sock ] && break; sleep 1; done

step "Cogy Server's private network"
control_url=$(tailscale debug prefs 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("ControlURL", ""))
except ValueError: print("")' || true)
ip=$(private_ip)
same_server=0
if [ -z "$LOGIN_SERVER" ] || [ "${control_url%/}" = "${LOGIN_SERVER%/}" ]; then same_server=1; fi
if [ -n "$ip" ] && [ "$same_server" -eq 1 ]; then
    info "Already joined ($control_url)"
else
    if [ -z "$LOGIN_SERVER" ]; then
        fail "This machine is not on Cogy Server's private network. Ask the owner for a join key
(Cogy Server > Machines > Add a machine to the network), then run:
    ./join-network.sh --login-server http://<server-ip>:8780"
    fi
    if [ -z "$AUTH_KEY" ]; then
        [ -t 0 ] || fail 'No join key: give --auth-key, or run in a terminal to be asked for it'
        read -r -s -p '    Join key: ' AUTH_KEY </dev/tty; echo
        [ -n "$AUTH_KEY" ] || fail 'No join key given'
    fi
    KEY_FILE=$(mktemp /run/cogy-join.XXXXXX)
    chmod 600 "$KEY_FILE"
    printf '%s' "$AUTH_KEY" > "$KEY_FILE"
    info "Joining $LOGIN_SERVER"
    if ! tailscale up --login-server "$LOGIN_SERVER" --auth-key "file:$KEY_FILE" --reset --timeout 120s; then
        fail "tailscale up failed. Check that $LOGIN_SERVER is reachable from this machine; use the server's IP address."
    fi
    for _ in $(seq 60); do ip=$(private_ip); [ -n "$ip" ] && break; sleep 1; done
    [ -n "$ip" ] || fail "Joined, but no address in $PRIVATE_RANGE was assigned"
fi
info "Private address: $ip"
printf '\n\033[32mJOINED: this machine is on Cogy Server'"'"'s private network at %s\033[0m\n' "$ip"
