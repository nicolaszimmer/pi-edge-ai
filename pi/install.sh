#!/usr/bin/env bash
# One-shot installer: llama.cpp + Gemma 4 E2B/E4B as a systemd service on a
# Raspberry Pi 5. Run it as your normal user from this directory (it calls
# sudo when needed). Safe to re-run: it keeps your existing config and API key.
#
#   ./install.sh                             # Gemma 4 E2B + E4B
#   MODELS=e2b ./install.sh                  # only E2B (smaller download)
#   MODELS="e2b e4b qwen3.5-4b" ./install.sh # plus Qwen 3.5 4B (./download-models.sh --list)
#
# More models later: ./add-model.sh. Web search: ./web-search.sh on.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX=/opt/pi-llm
CONF=/etc/pi-llm
SERVICE_USER=llm
MODELS="${MODELS:-e2b e4b}"

# shellcheck source=common.sh
. "$HERE/common.sh"
log() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script uses sudo itself)"

# --- Preflight -------------------------------------------------------------
log "Checking the system"
[[ "$(uname -m)" == "aarch64" ]] || die "needs 64-bit Raspberry Pi OS (aarch64), found $(uname -m)"
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)
echo "Board: $model"
[[ "$model" == *"Raspberry Pi 5"* ]] || warn "not a Raspberry Pi 5; the settings are tuned for one"
mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
echo "RAM: ${mem_gb} GB"
(( mem_gb >= 7 )) || warn "less than 8 GB RAM: use MODELS=e2b and remove the E4B section from models.ini"
free_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
echo "Free disk: ${free_gb} GB"
(( free_gb >= 12 )) || warn "less than 12 GB free; the build and both models need about 10 GB"

# --- Packages ---------------------------------------------------------------
log "Installing build dependencies"
sudo apt-get update
sudo apt-get install -y git cmake build-essential ccache libssl-dev openssl curl jq python3

# --- Build llama.cpp ---------------------------------------------------------
sudo mkdir -p "$PREFIX"
sudo chown "$(id -un):$(id -gn)" "$PREFIX"
log "Building llama.cpp"
PREFIX="$PREFIX" "$HERE/build-llama.sh"

# --- Models -----------------------------------------------------------------
log "Downloading models: $MODELS"
# shellcheck disable=SC2086  # MODELS is a space-separated list on purpose
MODELS_DIR="$PREFIX/models" "$HERE/download-models.sh" $MODELS

# --- Service user and config ----------------------------------------------------
log "Creating service user '$SERVICE_USER' and config in $CONF"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    sudo useradd --system --user-group --no-create-home --home-dir /var/lib/pi-llm \
        --shell /usr/sbin/nologin "$SERVICE_USER"
fi
sudo install -d -m 0755 "$CONF"

# Render models.ini, leaving out models whose files were not downloaded.
# Comment lines directly above a [section] belong to it and go with it.
rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
awk '
    function flush() { if (keep) printf "%s", buf; buf = "" }
    BEGIN { keep = 1 }
    /^[[:space:]]*;/ { pending = pending $0 ORS; next }
    /^\[/ { flush(); keep = 1 }
    { buf = buf pending $0 ORS; pending = "" }
    $1 == "model" && $2 == "=" { if (system("test -f \"" $3 "\"") != 0) keep = 0 }
    END { buf = buf pending; flush() }
' "$HERE/models.ini" > "$rendered"

install_config "$rendered" "$CONF/models.ini" 0644
install_config "$HERE/server.env" "$CONF/server.env" 0644

if ! sudo test -s "$CONF/api-keys"; then
    key="sk-pi-$(openssl rand -hex 20)"
    printf '# One API key per line. Restart the service after changes.\n%s\n' "$key" \
        | sudo tee "$CONF/api-keys" >/dev/null
    sudo chown "root:$SERVICE_USER" "$CONF/api-keys"
    sudo chmod 0640 "$CONF/api-keys"
fi

# Web search, if it was switched on before: update its tool script
if sudo test -f "$CONF/web-search.env"; then
    sudo install -d -m 0755 "$PREFIX/bin"
    sudo install -m 0755 "$HERE/web-search-mcp.py" "$PREFIX/bin/web-search-mcp.py"
fi

# --- systemd ------------------------------------------------------------------
log "Installing and starting the pi-llm service"
sudo install -m 0644 "$HERE/pi-llm.service" /etc/systemd/system/pi-llm.service
sudo systemctl daemon-reload
sudo systemctl enable pi-llm >/dev/null
sudo systemctl restart pi-llm

port=$(sed -n 's/^LLM_PORT=//p' "$CONF/server.env" | tail -1)
port="${port:-8080}"
key=$(sudo grep -v '^#' "$CONF/api-keys" | head -1)

echo -n "Waiting for the server to come up"
for _ in $(seq 1 60); do
    if curl -fs "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
    echo -n "."; sleep 2
done
echo
curl -fs "http://127.0.0.1:$port/health" >/dev/null \
    || die "server did not start; check: journalctl -u pi-llm -n 100 --no-pager"

log "Sending a test prompt (the first one also loads the model, give it a minute)"
"$HERE/test-api.sh" "http://127.0.0.1:$port" "$key" || warn "test failed; check: journalctl -u pi-llm -n 100 --no-pager"

host=$(hostname)
ip=$(hostname -I | awk '{print $1}')
cat <<EOF

$(printf '\033[1;32m')All set!$(printf '\033[0m')

  Web UI (any browser on your network):  http://$host.local:$port   (or http://$ip:$port)
  OpenAI-compatible API base URL:        http://$host.local:$port/v1
  API key:                               $key

  Models:   $(awk -F'[][]' '/^\[/ && $2 != "*" { print $2 }' "$CONF/models.ini" | paste -sd' ')
  Config:   $CONF/models.ini, $CONF/server.env, $CONF/api-keys
  Logs:     journalctl -u pi-llm -f
  Status:   $HERE/status.sh
  Speed:    $HERE/bench.sh

  More models (Qwen 3.5):  $HERE/add-model.sh
  Web search:              $HERE/web-search.sh on

EOF
