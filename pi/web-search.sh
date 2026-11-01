#!/usr/bin/env bash
# Web search for the models on your Pi.
#
#   ./web-search.sh on              # first time: pick a search engine and paste its key
#   ./web-search.sh off             # back to fully local (your settings are kept)
#   ./web-search.sh setup           # pick the search engine again
#   ./web-search.sh test [query]    # one search straight from the Pi, without the model
#   ./web-search.sh status
#
# Without questions, for scripts:
#   WEB_SEARCH_ENGINE=tavily TAVILY_API_KEY=tvly-... ./web-search.sh on
#
# The model gets two tools, web_search and web_fetch (web-search-mcp.py).
# llama-server's web UI calls them by itself and asks you before the first call.
# Search queries and the pages the model reads leave your network; the chat
# itself stays on the Pi.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

ENV_FILE="$CONF/web-search.env"
SCRIPT="$PREFIX/bin/web-search-mcp.py"
UNIT="${UNIT:-/etc/systemd/system/pi-llm.service}"

[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script uses sudo itself)"
[[ -d "$CONF" ]] || die "$CONF not found: run ./install.sh first"

# get <KEY> : current value in the env file (empty if unset or commented out)
get() { sudo sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1; }

# set_var <KEY> <value> : set (or un-comment) KEY in the env file
set_var() {
    local key="$1" value="$2" escaped
    [[ "$value" =~ ^[^[:space:]\"\'\\]*$ ]] || die "$key: spaces, quotes and backslashes are not supported"
    escaped=${value//&/\\&}
    escaped=${escaped//|/\\|}
    if sudo grep -q "^#\?$key=" "$ENV_FILE"; then
        sudo sed -i "s|^#\?$key=.*|$key=$escaped|" "$ENV_FILE"
    else
        echo "$key=$value" | sudo tee -a "$ENV_FILE" >/dev/null
    fi
}

is_on() { [[ -n "$(get LLAMA_ARG_MCP_SERVERS_CONFIG)" ]]; }

install_files() {
    log "Installing the web search tool"
    command -v python3 >/dev/null || sudo apt-get install -y python3
    sudo install -d -m 0755 "$PREFIX/bin"
    sudo install -m 0755 "$HERE/web-search-mcp.py" "$SCRIPT"
    install_config "$HERE/mcp.json" "$CONF/mcp.json" 0644
    if ! sudo test -f "$ENV_FILE"; then
        sudo install -m 0600 -o root -g root "$HERE/web-search.env" "$ENV_FILE"
        sudo sed -i 's|^LLAMA_ARG_MCP_SERVERS_CONFIG=|#&|' "$ENV_FILE"   # off until it works
    fi
    # Installs from before web search existed have a unit without web-search.env
    if ! grep -q 'web-search.env' "$UNIT" 2>/dev/null; then
        sudo install -m 0644 "$HERE/pi-llm.service" "$UNIT"
        sudo systemctl daemon-reload
    fi
}

# run_test <query> : search once with the service's settings, as the service user.
# Reads KEY=value lines like systemd does (no shell parsing, optional quotes).
run_test() {
    # shellcheck disable=SC2016  # the inner script is single-quoted on purpose
    sudo bash -c '
        printf -v q "\x27"
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
            key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
            if [[ ${#value} -ge 2 && ( "$value" == \"*\" || "$value" == "$q"*"$q" ) ]]; then
                value="${value:1:${#value}-2}"
            fi
            export "$key=$value"
        done < "$1"
        exec runuser -u "$2" -- python3 "$3" --search "$4"' \
        _ "$ENV_FILE" "$SERVICE_USER" "$SCRIPT" "$1"
}

show_tools() {
    local tools
    tools=$(curl -fsS -H "Authorization: Bearer $(api_key)" "http://127.0.0.1:$(server_port)/tools" 2>/dev/null \
        | jq -r '.[] | .tool' 2>/dev/null | paste -sd' ') || true
    echo "  Tools the server offers: ${tools:-none}"
}

choose_engine() {
    [[ -t 0 ]] || die "no search engine set; run this in a terminal, or: WEB_SEARCH_ENGINE=tavily TAVILY_API_KEY=... $0 on"
    cat <<'EOF'

Which search engine should the model use?

  1) Tavily   Made for AI assistants. Free plan: 1,000 searches a month, no credit card.
              Get a key at https://app.tavily.com
  2) Brave    Independent search index. A monthly free credit covers about 1,000 searches;
              signing up may ask for a payment card. https://api-dashboard.search.brave.com
  3) SearXNG  Your own meta-search server: no account, no key, most private. You set it
              up yourself first (see the README), then enter its URL here.

EOF
    local choice
    read -rp "Choice [1-3]: " choice
    case "$choice" in
        1) engine=tavily ;;
        2) engine=brave ;;
        3) engine=searxng ;;
        *) die "no search engine chosen" ;;
    esac
}

cmd_on() {
    local fresh="${1:-}" engine key_var value
    install_files

    engine="${WEB_SEARCH_ENGINE:-}"
    [[ -n "$engine" || -n "$fresh" ]] || engine=$(get WEB_SEARCH_ENGINE)
    [[ -n "$engine" ]] || choose_engine
    case "$engine" in
        tavily)  key_var=TAVILY_API_KEY ;;
        brave)   key_var=BRAVE_API_KEY ;;
        searxng) key_var=SEARXNG_URL ;;
        *)       die "unknown search engine '$engine' (use tavily, brave or searxng)" ;;
    esac

    value="${!key_var:-}"
    [[ -n "$value" || -n "$fresh" ]] || value=$(get "$key_var")
    if [[ -z "$value" ]]; then
        [[ -t 0 ]] || die "$key_var is not set"
        if [[ "$engine" == searxng ]]; then
            read -rp "SearXNG URL [http://127.0.0.1:8888]: " value
            value="${value:-http://127.0.0.1:8888}"
        else
            read -rsp "$key_var (input hidden): " value
            echo
        fi
    fi
    [[ -n "$value" ]] || die "$key_var is empty"
    set_var WEB_SEARCH_ENGINE "$engine"
    set_var "$key_var" "$value"

    log "Test search with $engine"
    run_test "Raspberry Pi 5" \
        || die "the test search failed (see above). Fix it and run '$0 on' again; web search was not switched on"

    set_var LLAMA_ARG_MCP_SERVERS_CONFIG "$CONF/mcp.json"
    log "Restarting pi-llm"
    restart_service
    show_tools
    cat <<EOF

Web search is on (engine: $engine).

  The model now has web_search and web_fetch. In the web UI, the chat asks for
  permission the first time it wants to search ("Always allow" skips that); you
  can switch the tools off under Settings > Tools.

  Off again:  $0 off
EOF
}

cmd_off() {
    if ! sudo test -f "$ENV_FILE" || ! is_on; then
        echo "Web search is already off."
        return
    fi
    sudo sed -i 's|^LLAMA_ARG_MCP_SERVERS_CONFIG=|#&|' "$ENV_FILE"
    log "Restarting pi-llm"
    restart_service
    echo "Web search is off. Your settings stay in $ENV_FILE; '$0 on' switches it back on."
}

cmd_status() {
    if ! sudo test -f "$ENV_FILE"; then
        echo "Web search: not set up (run $0 on)"
        return
    fi
    if is_on; then echo "Web search: on"; else echo "Web search: off"; fi
    echo "  Engine: $(get WEB_SEARCH_ENGINE)"
    show_tools
}

cmd_test() {
    if ! sudo test -f "$ENV_FILE" || ! sudo test -f "$SCRIPT"; then
        die "not set up yet: run $0 on"
    fi
    run_test "${1:-Raspberry Pi 5}"
}

case "${1:-}" in
    on)     cmd_on ;;
    setup)  cmd_on fresh ;;
    off)    cmd_off ;;
    status) cmd_status ;;
    test)   cmd_test "${2:-}" ;;
    *)      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
