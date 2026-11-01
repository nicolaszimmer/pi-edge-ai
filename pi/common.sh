# Shared helpers for the pi-llm scripts:  . "$HERE/common.sh"
# shellcheck shell=bash

PREFIX="${PREFIX:-/opt/pi-llm}"
CONF="${CONF:-/etc/pi-llm}"
SERVICE_USER="${SERVICE_USER:-llm}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# install_config <src> <dest> <mode> : never overwrite a file the user edited
install_config() {
    local src="$1" dest="$2" mode="$3"
    if ! sudo test -f "$dest"; then
        sudo install -m "$mode" -o root -g "$SERVICE_USER" "$src" "$dest"
    elif ! sudo cmp -s "$src" "$dest"; then
        sudo install -m "$mode" -o root -g "$SERVICE_USER" "$src" "$dest.new"
        warn "kept your $dest; the new version is in $dest.new"
    fi
}

server_port() {
    local port
    port=$(sed -n 's/^LLM_PORT=//p' "$CONF/server.env" 2>/dev/null | tail -1)
    echo "${port:-8080}"
}

api_key() { sudo grep -v '^#' "$CONF/api-keys" | head -1; }

# restart_service : restart pi-llm and wait until the API answers again
restart_service() {
    local url
    url="http://127.0.0.1:$(server_port)/health"
    sudo systemctl restart pi-llm
    echo -n "Waiting for the server"
    for _ in $(seq 1 60); do
        if curl -fs "$url" >/dev/null 2>&1; then echo " up."; return 0; fi
        echo -n "."; sleep 2
    done
    echo
    die "server did not come back; check: journalctl -u pi-llm -n 100 --no-pager"
}
