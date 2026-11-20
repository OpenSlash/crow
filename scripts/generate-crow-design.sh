#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TZ_OPENAI_API_KEY:-}" ]]; then
  echo "Missing TZ_OPENAI_API_KEY. Set it in your shell before running this script." >&2
  exit 1
fi

if [[ -z "${TZ_OPENAI_BASE_URL:-}" ]]; then
  echo "Missing TZ_OPENAI_BASE_URL. Example: export TZ_OPENAI_BASE_URL=https://api.tu-zi.com/v1" >&2
  exit 1
fi

python3 scripts/generate_image_compatible.py \
  --model gpt-image-2 \
  --prompt-file tmp/imagegen/crow-mvp-console-prompt.txt \
  --size 2048x1152 \
  --quality high \
  --output-format png \
  --out output/imagegen/crow-mvp-console.png
