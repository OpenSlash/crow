#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TZ_OPENAI_API_KEY:-}" ]]; then
  echo "Missing TZ_OPENAI_API_KEY. Export it before running this script." >&2
  exit 1
fi

if [[ -z "${TZ_OPENAI_BASE_URL:-}" ]]; then
  echo "Missing TZ_OPENAI_BASE_URL. Example: export TZ_OPENAI_BASE_URL=https://api.tu-zi.com/v1" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="output/imagegen/crow-island-v2"
mkdir -p "$OUT_DIR"

generate() {
  local name="$1"
  local prompt_file="$2"
  local size="${3:-1536x1024}"

  python3 scripts/generate_image_compatible.py \
    --model gpt-image-2 \
    --prompt-file "$prompt_file" \
    --size "$size" \
    --quality high \
    --output-format png \
    --out "$OUT_DIR/$name.png"
}

generate "crow-island-product-blueprint-v2" "tmp/imagegen/crow-island-product-blueprint-v2-prompt.txt" "1536x1024"
generate "crow-island-voice-v2" "tmp/imagegen/crow-island-voice-v2-prompt.txt" "1536x1024"
generate "crow-island-task-progress-v2" "tmp/imagegen/crow-island-task-progress-v2-prompt.txt" "1536x1024"
generate "crow-island-approval-v2" "tmp/imagegen/crow-island-approval-v2-prompt.txt" "1536x1024"
generate "crow-island-preview-v2" "tmp/imagegen/crow-island-preview-v2-prompt.txt" "1536x1024"

echo "Generated Crow Island V2 images in $OUT_DIR"
