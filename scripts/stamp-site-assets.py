#!/usr/bin/env python3
"""Tie Baton's unbundled CSS and JS links to their current file contents."""
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import sys

SITE = Path(__file__).resolve().parents[1] / "website"
# A root-relative link ("/styles.css") is stamped too: 404.html uses one so that a
# missing nested path such as /a/b/c still loads the stylesheet (TBX-8130).
LINK = re.compile(r'((?:href|src)="/?(?:styles\.css|main\.js))(?:\?v=[A-Za-z0-9_-]+)?(")')


def stamp(text: str) -> tuple[str, list[str]]:
    stale: list[str] = []

    def replace(match: re.Match[str]) -> str:
        head, quote = match.groups()
        name = head.split('"', 1)[1].lstrip("/")
        asset = SITE / name
        if not asset.is_file():
            stale.append(f"{name}: linked file is missing")
            return match.group(0)
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()[:12]
        updated = f"{head}?v={digest}{quote}"
        if match.group(0) != updated:
            stale.append(f"{name}: stale or missing content hash")
        return updated

    return LINK.sub(replace, text), stale


def main() -> int:
    check = sys.argv[1:] == ["--check"]
    if sys.argv[1:] and not check:
        print("usage: stamp-site-assets.py [--check]", file=sys.stderr)
        return 2
    pages = sorted(SITE.glob("*.html"))
    if not pages:
        print("no HTML pages found", file=sys.stderr)
        return 2
    problems = []
    for page in pages:
        original = page.read_text()
        updated, stale = stamp(original)
        problems.extend(f"{page.name}: {item}" for item in stale)
        if not check and updated != original:
            page.write_text(updated)
    if check and problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print(f"{len(pages)} HTML pages, {len(problems)} links {'checked' if check else 'stamped'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
