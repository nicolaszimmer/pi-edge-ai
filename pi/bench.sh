#!/usr/bin/env bash
# Measure how fast your Pi runs the models.
#
#   ./bench.sh              # API benchmark of every model the server offers
#   ./bench.sh api gemma-4-e4b
#   ./bench.sh raw          # llama-bench on the GGUF files (stops the service while it runs)
#   ./bench.sh raw qwen3.5-4b
#
# Use the API mode to A/B-test settings in /etc/pi-llm/models.ini, for example
# MTP speculative decoding or thread count: run, edit, restart the service, run again.
set -euo pipefail

MODE="${1:-api}"; shift || true
URL="${LLM_URL:-http://127.0.0.1:8080}"
KEY="${LLM_API_KEY:-}"
PREFIX="${PREFIX:-/opt/pi-llm}"
BIN="$PREFIX/llama.cpp/build/bin"
INI="${INI:-/etc/pi-llm/models.ini}"

if [[ -z "$KEY" && -f /etc/pi-llm/api-keys ]]; then
    KEY=$(sudo grep -v '^#' /etc/pi-llm/api-keys | head -1)
fi

chat() { # chat <json-body> -> response json
    curl -fsS -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
        "$URL/v1/chat/completions" -d "$1"
}

bench_api() {
    local ids=("$@")
    if [[ ${#ids[@]} -eq 0 ]]; then
        mapfile -t ids < <(curl -fsS -H "Authorization: Bearer $KEY" "$URL/v1/models" | jq -r '.data[].id')
    fi

    # ~700-token prompt for measuring prompt processing
    local para="The Raspberry Pi is a series of small single-board computers developed in the United Kingdom by the Raspberry Pi Foundation in association with Broadcom. It is widely used in education, hobby electronics, home automation and industrial applications because it is cheap, low-power and well documented. "
    local long=""
    for _ in $(seq 1 12); do long+="$para"; done

    printf '\n%-14s %8s %12s %12s %14s\n' "model" "load s" "prompt t/s" "gen t/s" "MTP accepted"
    printf '%-14s %8s %12s %12s %14s\n' "-----" "------" "----------" "-------" "------------"
    local id t0 t1 load pp tg resp
    for id in "${ids[@]}"; do
        # 1) make sure the model is loaded (the router loads it on first use)
        t0=$(date +%s.%N)
        chat "$(jq -n --arg m "$id" '{model: $m, max_tokens: 1, messages: [{role: "user", content: "Hi"}]}')" >/dev/null
        t1=$(date +%s.%N)
        load=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')

        # 2) prompt processing speed (cache off so it is measured from scratch)
        resp=$(chat "$(jq -n --arg m "$id" --arg p "$long" '{model: $m, max_tokens: 1, cache_prompt: false,
            messages: [{role: "user", content: ($p + "\n\nSummarize this in one sentence.")}]}')")
        pp=$(echo "$resp" | jq -r '.timings.prompt_per_second | . * 10 | floor / 10')

        # 3) generation speed, with the model's normal sampling settings and a fixed seed
        resp=$(chat "$(jq -n --arg m "$id" '{model: $m, max_tokens: 200, seed: 42, cache_prompt: false,
            messages: [{role: "user", content: "Write a short story (about 150 words) about a lighthouse keeper who adopts a seagull."}]}')")
        tg=$(echo "$resp" | jq -r '.timings.predicted_per_second | . * 10 | floor / 10')
        local mtp
        mtp=$(echo "$resp" | jq -r 'if (.timings.draft_n // 0) > 0
            then "\(.timings.draft_n_accepted)/\(.timings.draft_n) (\(.timings.draft_n_accepted * 100 / .timings.draft_n | floor)%)"
            else "off" end')
        printf '%-14s %8s %12s %12s %14s\n' "$id" "$load" "$pp" "$tg" "$mtp"
    done
    echo
    echo "load s includes switching models (only one fits in RAM at a time)."
}

bench_raw() {
    # every model in models.ini (or only the ones named on the command line)
    local files=() name path
    while read -r name path; do
        if [[ $# -gt 0 && ! " $* " == *" $name "* ]]; then continue; fi
        [[ -f "$path" ]] && files+=(-m "$path")
    done < <(awk -F'[][]' '/^\[/ { name = $2 } $1 ~ /^model[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print name, $0 }' "$INI")
    [[ ${#files[@]} -gt 0 ]] || { echo "no model files found (from $INI)" >&2; exit 1; }

    if systemctl is-active --quiet pi-llm 2>/dev/null; then
        echo "Stopping pi-llm to free RAM for the benchmark (restarted afterwards)..."
        sudo systemctl stop pi-llm
        trap 'echo "Restarting pi-llm"; sudo systemctl start pi-llm' EXIT
    fi
    # pp512 = prompt processing, tg128 = text generation; compares 3 vs 4 threads
    "$BIN/llama-bench" "${files[@]}" -t 3,4 -p 512 -n 128 -r 2 -o md
}

case "$MODE" in
    api) bench_api "$@" ;;
    raw) bench_raw "$@" ;;
    *)   echo "usage: $0 [api [model...] | raw [model...]]" >&2; exit 1 ;;
esac
