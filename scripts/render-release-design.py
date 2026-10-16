#!/usr/bin/env python3
"""Render docs/release-design.html, the visual companion of docs/release-design.md.

    python3 scripts/render-release-design.py          # write the page
    python3 scripts/render-release-design.py --check  # exit 1 if the page is out of date

The Markdown file is the source of truth (TBX-11003). This copies each "Diagram" section
of it into a standalone page: the heading, the prose and tables before the last diagram in
that section, and every Mermaid block.

    python3 scripts/render-release-design.py --render-svgs   # redraw the diagrams (needs network)

Each diagram is drawn once, by headless Chrome running the pinned Mermaid build, and kept as
docs/release-design-diagrams/<sha>.svg, named by the digest of its Mermaid source. The page
inlines those SVGs, so it works offline, from any folder and with scripts blocked. A diagram
whose source changed has no matching SVG; the page then falls back to drawing it from the CDN,
and --check reports it so the SVGs are redrawn.
"""
import hashlib
import html
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs" / "release-design.md"
TARGET = ROOT / "docs" / "release-design.html"
MERMAID = "https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"
SVG_DIR = ROOT / "docs" / "release-design-diagrams"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# Gantt timelines carry many labelled bars: draw them wide and readable, and let the figure
# scroll sideways rather than shrink the text to fit the column.
MERMAID_CONFIG = ('{ startOnLoad: true, securityLevel: "strict", theme: "default", '
                  'gantt: { useWidth: 1600, barHeight: 26, barGap: 6, fontSize: 14, '
                  'sectionFontSize: 15, leftPadding: 120, useMaxWidth: false } }')


def digest(source):
    return hashlib.sha256(source.encode()).hexdigest()[:16]


def stored_svg(source):
    path = SVG_DIR / ("%s.svg" % digest(source))
    return path.read_text() if path.exists() else None


def inline(text):
    """Escape, then the little Markdown the prose uses: code, bold, links."""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)

    def link(match):
        label, href = match.group(1), match.group(2)
        return '<a href="%s">%s</a>' % (html.escape(href), label)

    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, out)


def table(rows):
    cells = [[c.strip() for c in row.strip().strip("|").split("|")] for row in rows]
    head, body = cells[0], [r for r in cells[2:]]
    parts = ['<div class="table"><table><thead><tr>']
    parts += ["<th>%s</th>" % inline(c) for c in head]
    parts.append("</tr></thead><tbody>")
    for row in body:
        parts.append("<tr>" + "".join("<td>%s</td>" % inline(c) for c in row) + "</tr>")
    parts.append("</tbody></table></div>")
    return "".join(parts)


def sections(markdown):
    """Yield (level, title, lines) for every ## and ### heading."""
    current = None
    for line in markdown.splitlines():
        heading = re.match(r"^(#{2,3}) (.*)$", line)
        if heading and not (current and current[3]):
            if current:
                yield current[:3]
            current = [len(heading.group(1)), heading.group(2), [], False]
            continue
        if current is not None:
            current[2].append(line)
            if line.startswith("```"):
                current[3] = not current[3]
    if current:
        yield current[:3]


DRAWING = False


def render_section(title, lines):
    """Prose, tables and diagrams up to and including the section's last diagram."""
    last = max(i for i, line in enumerate(lines) if line.strip() == "```mermaid")
    end = last + next(i for i, line in enumerate(lines[last + 1:], 1) if line.startswith("```"))
    lines = lines[: end + 1]
    out = ['<section><h2>%s</h2>' % inline(title)]
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "```mermaid":
            j = i + 1
            while not lines[j].startswith("```"):
                j += 1
            source = "\n".join(lines[i + 1:j])
            svg = stored_svg(source)
            if svg and not DRAWING:
                wide = " wide" if source.lstrip().startswith("gantt") else ""
                out.append('<figure class="drawn%s">%s</figure>' % (wide, svg))
            else:
                out.append('<figure><pre class="mermaid" data-sha="%s">%s</pre></figure>'
                           % (digest(source), html.escape(source, quote=False)))
            i = j + 1
        elif line.startswith("|"):
            j = i
            while j < len(lines) and lines[j].startswith("|"):
                j += 1
            out.append(table(lines[i:j]))
            i = j
        elif line.strip():
            j = i
            while j < len(lines) and lines[j].strip() and not lines[j].startswith(("|", "```")):
                j += 1
            out.append("<p>%s</p>" % inline(" ".join(l.strip() for l in lines[i:j])))
            i = j
        else:
            i += 1
    out.append("</section>")
    return "\n".join(out)


def page(markdown):
    body = [render_section(title, lines)
            for level, title, lines in sections(markdown)
            if any(line.strip() == "```mermaid" for line in lines)]
    return """<!doctype html>
<!-- Generated by scripts/render-release-design.py from docs/release-design.md. Do not edit. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Baton Release Diagrams</title>
<style>
:root { --bg: #fbfaf7; --fg: #1f2328; --muted: #57606a; --line: #d8dee4; --card: #ffffff; --accent: #0b6bcb; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0f1115; --fg: #e6edf3; --muted: #9aa4ae; --line: #30363d; --card: #161b22; --accent: #58a6ff; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
main { max-width: 1100px; margin: 0 auto; padding: 24px 16px 64px; }
h1 { font-size: 1.8rem; margin: 0 0 4px; }
h2 { font-size: 1.25rem; margin: 40px 0 8px; }
p { max-width: 75ch; }
a { color: var(--accent); }
code { font: 0.9em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--card); border: 1px solid var(--line); border-radius: 4px; padding: 0 4px; }
.lede { color: var(--muted); }
figure { margin: 16px 0; padding: 16px; background: var(--card); border: 1px solid var(--line); border-radius: 8px; overflow-x: auto; }
pre.mermaid { margin: 0; white-space: pre; font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }
pre.mermaid[data-processed] { white-space: normal; text-align: center; }
figure.drawn { background: #ffffff; text-align: center; }
figure.drawn svg { height: auto; max-width: 100%%; }
figure.drawn.wide svg { max-width: none; }
.table { overflow-x: auto; }
table { border-collapse: collapse; margin: 12px 0; font-size: 0.92rem; }
th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; vertical-align: top; }
th { background: var(--card); }
#offline { color: var(--muted); font-size: 0.9rem; }
</style>
</head>
<body>
<main>
<h1>Baton release diagrams</h1>
<p class="lede">The diagrams of <a href="release-design.md">release-design.md</a>, TBX-11003. That file is the source of truth and explains each one; this page is generated from it.</p>
<p id="offline" hidden>A diagram changed since the drawings were made, so it is drawn from a CDN; without a network its source is shown instead.</p>
%s
</main>
<script src="%s"></script>
<script>
if (document.querySelector("pre.mermaid")) {
  if (window.mermaid) { window.mermaid.initialize(%s); }
  else { document.getElementById("offline").hidden = false; }
}
</script>
</body>
</html>
""" % ("\n".join(body), MERMAID, MERMAID_CONFIG)


def sources(markdown):
    return re.findall(r"^```mermaid\n(.*?)\n```", markdown, flags=re.M | re.S)


def render_svgs(markdown):
    """Draw every diagram in headless Chrome and keep each SVG under its source digest."""
    global DRAWING
    DRAWING = True
    with tempfile.TemporaryDirectory() as tmp:
        draft = Path(tmp) / "draw.html"
        draft.write_text(page(markdown))
        dom = subprocess.run([CHROME, "--headless", "--disable-gpu", "--virtual-time-budget=20000",
                              "--dump-dom", draft.as_uri()], capture_output=True, text=True, timeout=120).stdout
    DRAWING = False
    drawn = re.findall(r'<pre class="mermaid" data-sha="([0-9a-f]+)"[^>]*>(<svg.*?</svg>)', dom, flags=re.S)
    wanted = {digest(src) for src in sources(markdown)}
    got = {sha: svg for sha, svg in drawn if sha in wanted}
    missing = wanted - set(got)
    if missing:
        print("could not draw %d diagram(s): %s" % (len(missing), ", ".join(sorted(missing))))
        return 1
    SVG_DIR.mkdir(exist_ok=True)
    for old in SVG_DIR.glob("*.svg"):
        if old.stem not in wanted:
            old.unlink()
    for sha, svg in got.items():
        (SVG_DIR / ("%s.svg" % sha)).write_text(svg + "\n")
    print("drew %d diagram(s) into %s" % (len(got), SVG_DIR.relative_to(ROOT)))
    return 0


def main():
    markdown = SOURCE.read_text()
    if "--render-svgs" in sys.argv[1:]:
        if render_svgs(markdown):
            return 1
    rendered = page(markdown)
    stale = [digest(src) for src in sources(markdown) if stored_svg(src) is None]
    if "--check" in sys.argv[1:] and stale:
        print("%d diagram drawing(s) are missing or stale: run python3 scripts/render-release-design.py --render-svgs"
              % len(stale))
        return 1
    if "--check" in sys.argv[1:]:
        if not TARGET.exists() or TARGET.read_text() != rendered:
            print("docs/release-design.html is out of date: run python3 scripts/render-release-design.py")
            return 1
        print("docs/release-design.html matches docs/release-design.md")
        return 0
    TARGET.write_text(rendered)
    print("wrote %s" % TARGET.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
