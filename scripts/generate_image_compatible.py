#!/usr/bin/env python3
import argparse
import base64
import os
import sys
import time
import urllib.request
from pathlib import Path

from openai import OpenAI


def die(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--model", default="gpt-image-2")
    parser.add_argument("--size", default="1536x1024")
    parser.add_argument("--quality", default="medium")
    parser.add_argument("--output-format", default="png")
    args = parser.parse_args()

    api_key = os.getenv("TZ_OPENAI_API_KEY")
    base_url = os.getenv("TZ_OPENAI_BASE_URL")
    if not api_key:
        die("TZ_OPENAI_API_KEY is not set")
    if not base_url:
        die("TZ_OPENAI_BASE_URL is not set")

    prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    client = OpenAI(api_key=api_key, base_url=base_url)

    started = time.time()
    print("Calling image API...", file=sys.stderr)
    result = client.images.generate(
        model=args.model,
        prompt=prompt,
        n=1,
        size=args.size,
        quality=args.quality,
        output_format=args.output_format,
    )
    print(f"Generation completed in {time.time() - started:.1f}s.", file=sys.stderr)

    if not result.data:
        die("image API returned no data")

    item = result.data[0]
    payload = item.model_dump(exclude_none=True)

    image_b64 = payload.get("b64_json")
    image_url = payload.get("url")

    if image_b64:
        out_path.write_bytes(base64.b64decode(image_b64))
        print(f"Wrote {out_path}")
        return 0

    if image_url:
        with urllib.request.urlopen(image_url, timeout=120) as response:
            out_path.write_bytes(response.read())
        print(f"Wrote {out_path}")
        return 0

    visible_keys = ", ".join(sorted(payload.keys())) or "none"
    die(f"image API returned no b64_json or url; keys: {visible_keys}")


if __name__ == "__main__":
    raise SystemExit(main())
