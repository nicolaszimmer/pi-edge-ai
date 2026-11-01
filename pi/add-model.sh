#!/usr/bin/env bash
# Add a model to the installed server: download it, add its section to
# /etc/pi-llm/models.ini and restart the service.
#
#   ./add-model.sh                 # list the models you can add
#   ./add-model.sh qwen3.5-4b      # add one (or several: qwen3.5-2b qwen3.5-4b)
#
# The new model then shows up in the web UI's model list, in the iOS app and in
# GET /v1/models. Only one model sits in RAM at a time, so every extra model
# costs disk space, not memory.
#
# To remove a model, delete its [section] from /etc/pi-llm/models.ini, restart
# the service (sudo systemctl restart pi-llm) and delete its files from
# /opt/pi-llm/models.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

INI="$CONF/models.ini"

[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script uses sudo itself)"
[[ -f "$INI" ]] || die "$INI not found: run ./install.sh first"

# section <name> : the [name] section of the repo's models.ini, with the
# comment lines directly above it, without trailing comments and blank lines
section() {
    awk -v name="[$1]" '
        /^\[/ {
            if (insec) exit
            if ($0 == name) { insec = 1; printf "\n%s", pending }
        }
        insec { lines[++n] = $0; next }
        /^[[:space:]]*;/ { pending = pending $0 ORS; next }
        { pending = "" }
        END {
            while (n > 0 && lines[n] ~ /^[[:space:]]*(;.*)?$/) n--
            for (i = 1; i <= n; i++) print lines[i]
        }
    ' "$HERE/models.ini"
}

installed() { grep -qxF "[$1]" "$INI"; }

if [[ $# -eq 0 ]]; then
    echo "Models you can add (* = already installed):"
    for name in $("$HERE/download-models.sh" --list); do
        if installed "$name"; then echo "  * $name"; else echo "    $name"; fi
    done
    echo
    echo "Usage: $0 <name>...    for example: $0 qwen3.5-4b"
    exit 0
fi

names=()
for arg in "$@"; do
    case "$arg" in e2b) arg=gemma-4-e2b ;; e4b) arg=gemma-4-e4b ;; esac
    [[ -n "$(section "$arg")" ]] || die "unknown model '$arg' (run $0 without arguments for the list)"
    names+=("$arg")
done

log "Downloading ${names[*]}"
MODELS_DIR="$PREFIX/models" "$HERE/download-models.sh" "${names[@]}"

changed=0
for name in "${names[@]}"; do
    if installed "$name"; then
        log "[$name] is already in $INI"
    else
        section "$name" | sudo tee -a "$INI" >/dev/null
        log "Added [$name] to $INI"
        changed=1
    fi
done

if (( changed )); then
    log "Restarting pi-llm"
    restart_service
fi

echo
echo "Models on the server:"
curl -fsS -H "Authorization: Bearer $(api_key)" "http://127.0.0.1:$(server_port)/v1/models" \
    | jq -r '.data[] | "  \(.id): \(.status.value // "loaded")"' \
    || warn "could not list the models"
echo
echo "Pick the new model in the web UI's model menu. The first reply after a switch"
echo "waits while the Pi loads it. Speed check: ./bench.sh api ${names[0]}"
