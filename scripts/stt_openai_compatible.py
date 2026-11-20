#!/usr/bin/env python3
import argparse
import os
import sys
from pathlib import Path

from openai import OpenAI


def die(message: str) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio_path", nargs="?", default=os.getenv("CROW_AUDIO_PATH", ""))
    args = parser.parse_args()

    audio_path = Path(args.audio_path).expanduser()
    if not audio_path.exists():
        die(f"audio file does not exist: {audio_path}")

    api_key = os.getenv("TZ_OPENAI_API_KEY")
    base_url = os.getenv("TZ_OPENAI_BASE_URL")
    model = os.getenv("CROW_STT_MODEL", "whisper-1")
    language = os.getenv("CROW_STT_LANGUAGE", "")

    if not api_key:
        die("TZ_OPENAI_API_KEY is not set")
    if not base_url:
        die("TZ_OPENAI_BASE_URL is not set")

    client = OpenAI(api_key=api_key, base_url=base_url)

    kwargs = {"model": model}
    if language:
        kwargs["language"] = language

    with audio_path.open("rb") as audio_file:
        result = client.audio.transcriptions.create(file=audio_file, **kwargs)

    text = getattr(result, "text", "")
    if not text:
        payload = result.model_dump(exclude_none=True)
        text = str(payload.get("text", "")).strip()

    print(text.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
