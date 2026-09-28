#!/usr/bin/env python3
"""Read Valve KeyValues appworkshop data and emit installed timestamps as JSON."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

TOKEN = re.compile(r'"((?:\\.|[^"\\])*)"|([{}])')


def unescape(value: str) -> str:
    return value.replace(r"\\", "\\").replace(r'\"', '"')


def parse(text: str) -> dict:
    tokens = [unescape(m.group(1)) if m.group(1) is not None else m.group(2) for m in TOKEN.finditer(text)]
    position = 0

    def obj(expect_brace: bool = False) -> dict:
        nonlocal position
        if expect_brace:
            if position >= len(tokens) or tokens[position] != "{":
                raise ValueError("Invalid KeyValues format")
            position += 1
        result = {}
        while position < len(tokens):
            if tokens[position] == "}":
                position += 1
                return result
            key = tokens[position]
            position += 1
            if position >= len(tokens):
                raise ValueError("Missing value")
            if tokens[position] == "{":
                result[key] = obj(True)
            else:
                result[key] = tokens[position]
                position += 1
        return result

    return obj()


def main() -> int:
    argp = argparse.ArgumentParser()
    argp.add_argument("manifest", type=Path)
    args = argp.parse_args()
    if not args.manifest.exists():
        print("{}")
        return 0
    data = parse(args.manifest.read_text(encoding="utf-8", errors="replace"))
    app = data.get("AppWorkshop", {})
    installed = app.get("WorkshopItemsInstalled", {})
    result = {}
    for item_id, details in installed.items():
        if isinstance(details, dict):
            result[item_id] = {
                "time_updated": int(details.get("timeupdated", "0") or 0),
                "manifest": details.get("manifest", ""),
            }
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
