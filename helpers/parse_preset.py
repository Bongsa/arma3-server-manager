#!/usr/bin/env python3
"""Parse an Arma 3 Launcher preset with Python's tolerant HTML parser."""

from __future__ import annotations

import argparse
import html.parser
import json
import os
import re
import tempfile
import unicodedata
from pathlib import Path
from urllib.parse import parse_qs, urlparse


class PresetParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[dict[str, str]] = []
        self.row: dict[str, str] | None = None
        self.capture_name = False
        self.name_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs_list: list[tuple[str, str | None]]) -> None:
        attrs = dict(attrs_list)
        if tag.lower() == "tr" and attrs.get("data-type") == "ModContainer":
            self.row = {}
        if self.row is None:
            return
        if tag.lower() == "td" and attrs.get("data-type") == "DisplayName":
            self.capture_name = True
            self.name_parts = []
        if tag.lower() == "a":
            href = attrs.get("href") or ""
            query = parse_qs(urlparse(href).query)
            candidate = query.get("id", [""])[0]
            if re.fullmatch(r"[1-9][0-9]{4,19}", candidate):
                self.row["workshop_id"] = candidate

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "td" and self.capture_name:
            self.capture_name = False
            if self.row is not None:
                self.row["name"] = " ".join("".join(self.name_parts).split())
        if tag.lower() == "tr" and self.row is not None:
            if self.row.get("workshop_id") and self.row.get("name"):
                self.rows.append(self.row)
            self.row = None

    def handle_data(self, data: str) -> None:
        if self.capture_name:
            self.name_parts.append(data)


def slugify(value: str, workshop_id: str) -> str:
    ascii_name = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "_", ascii_name.lower()).strip("_")[:180].rstrip("_")
    return "@" + (slug or workshop_id)


def main() -> int:
    argp = argparse.ArgumentParser()
    argp.add_argument("input", type=Path)
    argp.add_argument("output", type=Path)
    argp.add_argument("--workshop-content", required=True, type=Path)
    args = argp.parse_args()

    parser = PresetParser()
    parser.feed(args.input.read_text(encoding="utf-8-sig", errors="strict"))
    parser.close()
    if not parser.rows:
        raise SystemExit("No Workshop mods found in the Launcher preset")

    seen_ids: set[str] = set()
    seen_links: set[str] = set()
    mods = []
    for row in parser.rows:
        item_id = row["workshop_id"]
        if item_id in seen_ids:
            continue
        seen_ids.add(item_id)
        link_name = slugify(row["name"], item_id)
        if link_name in seen_links:
            link_name = f"{link_name}_{item_id}"
        seen_links.add(link_name)
        mods.append(
            {
                "workshop_id": item_id,
                "name": row["name"],
                "type": "client",
                "classification": "heuristic-launcher-preset",
                "link_name": link_name,
                "local_path": str(args.workshop_content / item_id),
            }
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".mods.", suffix=".json", dir=args.output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(mods, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o640)
        os.replace(temporary, args.output)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    print(len(mods))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
