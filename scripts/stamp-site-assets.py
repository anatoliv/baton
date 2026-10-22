#!/usr/bin/env python3
"""Tie Baton's unbundled CSS and JS links, and each page's Content-Security-Policy, to the
current file contents."""
from __future__ import annotations

import base64
import hashlib
import os
from pathlib import Path
import re
import sys

SITE = Path(os.environ.get("BATON_SITE_DIR") or Path(__file__).resolve().parents[1] / "website")
# A root-relative link ("/styles.css") is stamped too: 404.html uses one so that a
# missing nested path such as /a/b/c still loads the stylesheet (TBX-8130).
LINK = re.compile(r'((?:href|src)="/?(?:styles\.css|main\.js))(?:\?v=[A-Za-z0-9_-]+)?(")')

# The static site's Content-Security-Policy (TBX-1000000503 E-10), one per page as a <meta>,
# because its script-src names the SHA-256 of that page's own inline scripts (the theme
# bootstrap before first paint, help.html's scrollspy). A changed inline script needs a new
# hash, or the browser refuses to run it; this stamper writes it and --check refuses a stale
# one, the same way it treats asset links. Styles allow 'unsafe-inline': the pages carry an
# inline <style> block and style="" attributes, which hashes cannot cover without
# 'unsafe-hashes'. frame-ancestors cannot be set from a <meta>; X-Frame-Options covers it,
# and nginx sends Permissions-Policy (deploy/nginx/default.conf).
CSP_META = re.compile(r'<meta http-equiv="Content-Security-Policy" content="[^"]*">\n?')
CHARSET = re.compile(r'(<meta charset="utf-8">\n)')
INLINE_SCRIPT = re.compile(r"<script>(.*?)</script>", re.S)


def csp_for(text: str) -> str:
    hashes = [
        "'sha256-" + base64.b64encode(hashlib.sha256(body.encode()).digest()).decode() + "'"
        for body in INLINE_SCRIPT.findall(text)
    ]
    script_src = " ".join(["'self'"] + hashes)
    return (
        f"default-src 'self'; script-src {script_src}; style-src 'self' 'unsafe-inline'; "
        "img-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'"
    )


def stamp_csp(text: str) -> tuple[str, list[str]]:
    want = f'<meta http-equiv="Content-Security-Policy" content="{csp_for(text)}">\n'
    found = CSP_META.findall(text)
    if found == [want]:
        return text, []
    if not CHARSET.search(text):
        return text, ['no <meta charset="utf-8"> line to place the Content-Security-Policy after']
    stripped = CSP_META.sub("", text)
    return CHARSET.sub(lambda m: m.group(1) + want, stripped, count=1), [
        "stale or missing Content-Security-Policy"
    ]


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

    text = LINK.sub(replace, text)
    text, csp_stale = stamp_csp(text)
    return text, stale + csp_stale


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
