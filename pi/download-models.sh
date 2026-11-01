#!/usr/bin/env bash
# Download model GGUF files from Hugging Face and verify their SHA-256.
#
#   ./download-models.sh                  # Gemma 4 E2B + E4B (~8.7 GB total)
#   ./download-models.sh e2b              # only Gemma 4 E2B (~3.5 GB)
#   ./download-models.sh qwen3.5-4b       # Qwen 3.5 4B (~3.3 GB)
#   ./download-models.sh ministral-3-3b   # Ministral 3 3B (~2.9 GB)
#   ./download-models.sh --list           # all model names this script knows
#
# To also add a model to an installed server, use ./add-model.sh instead.
#
# Gemma 4 comes from the official llama.cpp conversions in the ggml-org
# namespace. Their Q4_0 files are made from Google's quantization-aware-trained
# (QAT) checkpoints, so they lose very little quality compared to BF16. Q4_0 is
# also the fastest 4-bit format on the Pi 5 (repacked for ARM dotprod at load).
# Per Gemma model it fetches the language model, the vision encoder (mmproj,
# lets you send photos) and the multi-token-prediction draft head (mtp).
#
# Qwen 3.5 and Ministral 3 have no official Q4_0 GGUF, so they come from
# Unsloth's conversions (calibrated with an importance matrix). Unsloth names
# every vision encoder mmproj-F16.gguf, so it is saved under a per-model name.
# F16, not BF16: the Pi 5's Cortex-A76 has no BF16 instructions.
# Granite 4.2 and LFM2.5 come from IBM's and Liquid AI's own GGUF repos.
set -euo pipefail

MODELS_DIR="${MODELS_DIR:-/opt/pi-llm/models}"
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"

# name (= model ID in models.ini)   Hugging Face repo   files: remote[=local name]
CATALOG="
gemma-4-e2b  ggml-org/gemma-4-E2B-it-GGUF  gemma-4-E2B-it-Q4_0.gguf mmproj-gemma-4-E2B-it-Q8_0.gguf mtp-gemma-4-E2B-it-Q4_0.gguf
gemma-4-e4b  ggml-org/gemma-4-E4B-it-GGUF  gemma-4-E4B-it-Q4_0.gguf mmproj-gemma-4-E4B-it-Q8_0.gguf mtp-gemma-4-E4B-it-Q4_0.gguf
qwen3.5-2b   unsloth/Qwen3.5-2B-GGUF       Qwen3.5-2B-Q4_0.gguf mmproj-F16.gguf=mmproj-Qwen3.5-2B-F16.gguf
qwen3.5-4b   unsloth/Qwen3.5-4B-GGUF       Qwen3.5-4B-Q4_0.gguf mmproj-F16.gguf=mmproj-Qwen3.5-4B-F16.gguf
ministral-3-3b  unsloth/Ministral-3-3B-Instruct-2512-GGUF  Ministral-3-3B-Instruct-2512-Q4_0.gguf mmproj-F16.gguf=mmproj-Ministral-3-3B-F16.gguf
granite-4.2-3b  ibm-granite/granite-4.2-3b-GGUF  granite-4.2-3b-Q4_0.gguf
lfm2.5-8b-a1b   LiquidAI/LFM2.5-8B-A1B-GGUF      LFM2.5-8B-A1B-Q4_0.gguf
"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# canonical <name> : accept the short names e2b / e4b too
canonical() {
    case "$1" in
        e2b) echo gemma-4-e2b ;;
        e4b) echo gemma-4-e4b ;;
        *)   echo "$1" ;;
    esac
}

if [[ "${1:-}" == "--list" ]]; then
    awk 'NF { print $1 }' <<<"$CATALOG"
    exit 0
fi

command -v jq >/dev/null || die "jq is required (sudo apt install jq)"
command -v curl >/dev/null || die "curl is required (sudo apt install curl)"

models=()
for m in "${@:-e2b e4b}"; do
    for name in $m; do   # also split "e2b e4b" given as one argument
        name=$(canonical "$name")
        awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' <<<"$CATALOG" \
            || die "unknown model '$name' (known: $(awk 'NF { printf "%s ", $1 }' <<<"$CATALOG"))"
        models+=("$name")
    done
done

mkdir -p "$MODELS_DIR"

auth=()
[[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")

# download <repo> <manifest.json> <remote file> <local file>
download() {
    local repo="$1" manifest="$2" file="$3" dest="$MODELS_DIR/$4"
    local sha size
    sha=$(jq -r --arg p "$file" '.[] | select(.path == $p) | .lfs.oid // empty' "$manifest")
    size=$(jq -r --arg p "$file" '.[] | select(.path == $p) | .size // empty' "$manifest")
    [[ -n "$sha" && -n "$size" ]] || die "$file not found in $repo"

    if [[ -f "$dest" && "$(stat -c %s "$dest")" == "$size" ]]; then
        if echo "$sha  $dest" | sha256sum --check --status; then
            log "$4 already present and verified"
            return
        fi
        log "$4 is corrupt, downloading again"
        rm -f "$dest"
    fi

    local free_bytes have=0
    [[ -f "$dest.part" ]] && have=$(stat -c %s "$dest.part")
    free_bytes=$(df --output=avail -B1 "$MODELS_DIR" | tail -1)
    (( free_bytes > size - have )) || die "not enough disk space for $4 ($((size / 1000000)) MB needed)"

    log "Downloading $4 ($((size / 1000000)) MB) from $repo"
    # -C - resumes an interrupted download of the .part file
    curl -fL --progress-bar --retry 5 --retry-delay 5 -C - "${auth[@]}" \
        -o "$dest.part" "$HF_ENDPOINT/$repo/resolve/main/$file"

    log "Verifying $4"
    echo "$sha  $dest.part" | sha256sum --check --status \
        || { rm -f "$dest.part"; die "checksum mismatch for $4, run the script again"; }
    mv "$dest.part" "$dest"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for name in "${models[@]}"; do
    read -r -a entry < <(awk -v n="$name" '$1 == n' <<<"$CATALOG")
    repo="${entry[1]}"
    manifest="$tmp/$name.json"
    curl -fsSL "${auth[@]}" "$HF_ENDPOINT/api/models/$repo/tree/main" -o "$manifest" \
        || die "could not list files of $repo"
    for spec in "${entry[@]:2}"; do
        download "$repo" "$manifest" "${spec%%=*}" "${spec#*=}"
    done
done

log "Models in $MODELS_DIR:"
ls -lh "$MODELS_DIR"/*.gguf
