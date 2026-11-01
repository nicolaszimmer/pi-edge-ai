#!/usr/bin/env bash
# Download Gemma 4 GGUF files from Hugging Face and verify their SHA-256.
#
#   ./download-models.sh              # E2B + E4B (~8.7 GB total)
#   ./download-models.sh e2b          # only E2B (~3.5 GB)
#   ./download-models.sh e4b          # only E4B (~5.2 GB)
#
# Source: the official llama.cpp conversions in the ggml-org namespace.
# Their Q4_0 files are made from Google's quantization-aware-trained (QAT)
# Q4_0 checkpoints, so they lose very little quality compared to BF16. Q4_0 is
# also the fastest 4-bit format on the Pi 5 (repacked for ARM dotprod at load).
#
# Per model it fetches:
#   <name>-Q4_0.gguf          language model
#   mmproj-<name>-Q8_0.gguf   vision encoder (lets you send photos)
#   mtp-<name>-Q4_0.gguf      multi-token-prediction draft head (optional speed-up)
set -euo pipefail

MODELS_DIR="${MODELS_DIR:-/opt/pi-llm/models}"
HF_ENDPOINT="${HF_ENDPOINT:-https://huggingface.co}"

declare -A REPO=(
    [e2b]="ggml-org/gemma-4-E2B-it-GGUF"
    [e4b]="ggml-org/gemma-4-E4B-it-GGUF"
)
declare -A NAME=(
    [e2b]="gemma-4-E2B-it"
    [e4b]="gemma-4-E4B-it"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required (sudo apt install jq)"
command -v curl >/dev/null || die "curl is required (sudo apt install curl)"

models=("$@")
[[ ${#models[@]} -eq 0 ]] && models=(e2b e4b)
for m in "${models[@]}"; do
    [[ -n "${REPO[$m]:-}" ]] || die "unknown model '$m' (use: e2b, e4b)"
done

mkdir -p "$MODELS_DIR"

auth=()
[[ -n "${HF_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $HF_TOKEN")

# download <repo> <manifest.json> <file>
download() {
    local repo="$1" manifest="$2" file="$3"
    local dest="$MODELS_DIR/$file"
    local sha size
    sha=$(jq -r --arg p "$file" '.[] | select(.path == $p) | .lfs.oid // empty' "$manifest")
    size=$(jq -r --arg p "$file" '.[] | select(.path == $p) | .size // empty' "$manifest")
    [[ -n "$sha" && -n "$size" ]] || die "$file not found in $repo"

    if [[ -f "$dest" && "$(stat -c %s "$dest")" == "$size" ]]; then
        if echo "$sha  $dest" | sha256sum --check --status; then
            log "$file already present and verified"
            return
        fi
        log "$file is corrupt, downloading again"
        rm -f "$dest"
    fi

    local free_bytes have=0
    [[ -f "$dest.part" ]] && have=$(stat -c %s "$dest.part")
    free_bytes=$(df --output=avail -B1 "$MODELS_DIR" | tail -1)
    (( free_bytes > size - have )) || die "not enough disk space for $file ($((size / 1000000)) MB needed)"

    log "Downloading $file ($((size / 1000000)) MB)"
    # -C - resumes an interrupted download of the .part file
    curl -fL --progress-bar --retry 5 --retry-delay 5 -C - "${auth[@]}" \
        -o "$dest.part" "$HF_ENDPOINT/$repo/resolve/main/$file"

    log "Verifying $file"
    echo "$sha  $dest.part" | sha256sum --check --status \
        || { rm -f "$dest.part"; die "checksum mismatch for $file, run the script again"; }
    mv "$dest.part" "$dest"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for m in "${models[@]}"; do
    repo="${REPO[$m]}"; name="${NAME[$m]}"
    manifest="$tmp/$m.json"
    curl -fsSL "${auth[@]}" "$HF_ENDPOINT/api/models/$repo/tree/main" -o "$manifest" \
        || die "could not list files of $repo"
    for f in "$name-Q4_0.gguf" "mmproj-$name-Q8_0.gguf" "mtp-$name-Q4_0.gguf"; do
        download "$repo" "$manifest" "$f"
    done
done

log "Models in $MODELS_DIR:"
ls -lh "$MODELS_DIR"/*.gguf
