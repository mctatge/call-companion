#!/usr/bin/env python3
"""Refresh the live answer instructions without adding reference documents.

The app reads its bundled prompt for every request, so this updates future answers
without restarting the microphone or discarding the in-memory conversation.
"""

from pathlib import Path
import os
import tempfile


def main():
    companion = Path(__file__).resolve().parent
    resources = companion / ".build/Call Companion.app/Contents/Resources"
    prompt = (companion / "assistant-instructions.md").read_text()
    if not resources.is_dir():
        raise RuntimeError("Build the app before refreshing its instructions.")
    destination = resources / "assistant-instructions.md"
    with tempfile.NamedTemporaryFile(mode="w", dir=resources, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(prompt)
    try:
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Refreshed answer instructions ({len(prompt)} characters); reference files unchanged.")


if __name__ == "__main__":
    main()
