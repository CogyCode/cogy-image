# Helpers shared by join-network.sh, install.sh and uninstall.sh. Source it
# after setting REPO_DIR.
# shellcheck shell=bash

# shellcheck source=../config/settings.env
. "$REPO_DIR/config/settings.env"

SYSTEMD_DIR=/etc/systemd/system
UDEV_RULE=/etc/udev/rules.d/70-cogy-image-npu.rules

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# Re-runs the calling script with sudo unless already root.
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo 'Root rights needed; re-running with sudo...'
        # Through bash, so the script needs no executable bit and works when
        # started as "bash install.sh".
        exec sudo -- bash "$0" "$@"
    fi
}

# Prints dotted IPv4 address $1 as an integer.
ip_to_int() {
    local IFS=.
    # shellcheck disable=SC2086
    set -- $1
    echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}

# True when address $1 is inside CIDR range $2.
in_range() {
    local net=${2%/*} bits=${2#*/}
    local mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( $(ip_to_int "$1") & mask )) -eq $(( $(ip_to_int "$net") & mask )) ]
}

# This machine's address on Cogy Server's private network, or nothing when
# not joined.
private_ip() {
    command -v tailscale >/dev/null 2>&1 || return 0
    local ip
    ip=$(tailscale ip -4 2>/dev/null | sed -n 1p | tr -d '[:space:]')
    if [ -n "$ip" ] && in_range "$ip" "$PRIVATE_RANGE"; then
        echo "$ip"
    fi
}

# Writes template $1 to $2 with each @KEY@ replaced by the variable KEY. An
# @KEY@ with no such variable is an error, so nothing is left unfilled.
render() {
    local keys key
    keys=$(grep -oE '@[A-Z][A-Z0-9_]*@' "$1" | tr -d @ | sort -u)
    for key in $keys; do
        [ -n "${!key+set}" ] || fail "$1: no value for @$key@"
        export "R_$key=${!key}"
    done
    python3 - "$1" "$2" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
text = re.sub(r"@([A-Z][A-Z0-9_]*)@", lambda m: os.environ["R_" + m.group(1)], text)
with open(dst, "w", encoding="utf-8") as f:
    f.write(text)
PY
}

# Prints the SHA-256 of a file.
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# Downloads $1 to $3 unless $3 is already there with SHA-256 $2; checks it.
get_verified() {
    local url=$1 sha=$2 out=$3
    if [ -f "$out" ] && [ "$(sha256_of "$out")" = "$sha" ]; then
        info "Already downloaded: $(basename "$out")"
        return 0
    fi
    info "Downloading $url"
    curl -fL --retry 3 --progress-bar -o "$out.part" "$url" || fail "Download failed: $url"
    local got
    got=$(sha256_of "$out.part")
    if [ "$got" != "$sha" ]; then
        rm -f "$out.part"
        fail "SHA-256 mismatch for $(basename "$out"): got $got"
    fi
    mv "$out.part" "$out"
    info 'SHA-256 OK'
}
