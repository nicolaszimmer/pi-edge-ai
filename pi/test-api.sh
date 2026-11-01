#!/usr/bin/env bash
# Smoke-test the server's OpenAI-compatible API.
#
#   ./test-api.sh                                   # on the Pi itself
#   ./test-api.sh http://pi-llm.local:8080 sk-pi-…  # from another machine
#   ./test-api.sh <url> <key> gemma-4-e4b           # a specific model
set -euo pipefail

URL="${1:-${LLM_URL:-http://127.0.0.1:8080}}"
KEY="${2:-${LLM_API_KEY:-}}"
MODEL="${3:-}"

if [[ -z "$KEY" && -f /etc/pi-llm/api-keys ]]; then
    KEY=$(sudo grep -v '^#' /etc/pi-llm/api-keys | head -1)
fi
auth=(-H "Authorization: Bearer $KEY")

echo "1) Health"
curl -fsS "$URL/health"; echo

echo "2) Models"
models=$(curl -fsS "${auth[@]}" "$URL/v1/models")
echo "$models" | jq -r '.data[] | "   \(.id)  (\(.status.value // "loaded"))"'
[[ -n "$MODEL" ]] || MODEL=$(echo "$models" | jq -r '.data[0].id')

echo "3) Chat completion with $MODEL"
resp=$(curl -fsS "${auth[@]}" "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg m "$MODEL" '{
        model: $m,
        max_tokens: 80,
        messages: [{role: "user", content: "In two sentences: why is the sky blue?"}]
    }')")
echo "$resp" | jq -r '"   " + .choices[0].message.content'
echo "$resp" | jq -r '.timings | "   prompt: \(.prompt_n) tokens @ \(.prompt_per_second | floor) tok/s, generated: \(.predicted_n) tokens @ \(.predicted_per_second * 10 | floor / 10) tok/s"'
