#!/usr/bin/env python3
"""Lowercase a tree safely without following symlinks."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    if not root.is_dir():
        raise SystemExit(f"Not a mod directory: {root}")

    entries: list[Path] = []
    for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
        base = Path(current)
        # Symlink directories must be renamed but never traversed.
        real_dirs = []
        for name in dirs:
            path = base / name
            entries.append(path)
            if not path.is_symlink():
                real_dirs.append(name)
        dirs[:] = real_dirs
        entries.extend(base / name for name in files)

    # Preflight every sibling set. casefold catches collisions more broadly than lower.
    by_parent: dict[Path, dict[str, Path]] = {}
    for path in entries:
        key = path.name.lower().casefold()
        previous = by_parent.setdefault(path.parent, {}).get(key)
        if previous is not None and previous.name != path.name:
            raise SystemExit(f"Case collision: {previous} <-> {path}")
        by_parent[path.parent][key] = path

    changed = 0
    for path in sorted(entries, key=lambda p: len(p.parts), reverse=True):
        # Parents are still at their original names because this is depth-first.
        lowered = path.name.lower()
        if lowered == path.name:
            continue
        destination = path.with_name(lowered)
        if os.path.lexists(destination) and destination != path:
            raise SystemExit(f"Destination already exists: {destination}")
        if args.dry_run:
            print(f"{path} -> {destination}")
        else:
            os.rename(path, destination)
        changed += 1
    print(changed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
