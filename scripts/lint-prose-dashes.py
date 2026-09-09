#!/usr/bin/env python3
"""W-21: no em dash or en dash inside a string a user reads.

Published copy here is written without em dashes (U+2014) or en dashes (U+2012, U+2013):
each one is replaced by the punctuation the sentence actually wants, a period between two
independent clauses, a colon before a definition, parentheses around a true aside, a comma
only for a tight one. A blanket dash-to-comma swap produces comma splices and reads worse
than the dash did, so this lint reports and refuses rather than rewriting.

WHY IT EXISTS. The 0.19.0 copy pass fixed the strings a review had listed by hand. A count
afterwards found 74 more in 29 files, including the Settings, Remote, Linking hint, which a
line grep had missed because the string is backslash-continued across two source lines
(TBX-5348). A grep cannot see that, and it cannot tell a string from a comment either. So
this walks the Swift source with a real lexer: it knows single-line, multi-line and raw
string literals, string interpolation (including strings nested inside an interpolation),
line and block comments, and character escapes.

WHAT IT DOES NOT DO. Comments and documentation are out of scope, since nobody reads them
in the app. Arrows ("→") are out of scope too: the same glyph is prose punctuation in one
hint and a literal menu path in the next, and a lint that cannot tell them apart would be
noisy, and a noisy lint gets bypassed and then guards nothing.

DELIBERATE GLYPHS. A dash that is typography rather than prose (a leading kicker, a
metadata separator, a numeric range) goes in the allowlist file beside this script, with a
line of reasoning above it. The allowlist matches on the file path plus the trimmed text of
the source line, not on a line number, so it does not rot silently as the file moves around
and it does stop matching if the sentence itself is rewritten.

Usage:
    scripts/lint-prose-dashes.py [--allowlist FILE] [--print-allowlist] [ROOT ...]

Exit status is 1 when anything is reported, 0 when nothing is.
"""

import argparse
import os
import sys

# The three the copy rule names. U+2010/U+2011 (hyphen, non-breaking hyphen) are ordinary
# hyphenation and stay; U+2212 is a mathematical minus and has nothing to do with prose.
DASHES = {
    "‒": "U+2012 figure dash",
    "–": "U+2013 en dash",
    "—": "U+2014 em dash",
}

DEFAULT_ALLOWLIST = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "lint-prose-dashes-allowlist.txt"
)


def scan_string_literals(src):
    """Yield (line, column, char) for every DASHES character inside a string literal.

    A hand-written scanner rather than a regex, because Swift string literals nest: an
    interpolation segment holds arbitrary code, which can hold another string literal,
    which can hold another interpolation. Tracking that needs a stack.
    """
    hits = []
    n = len(src)
    i = 0
    line = 1
    col = 1
    # Stack of open contexts. Each is either
    #   ("code", paren_depth)   -- ordinary source, or an interpolation segment
    #   ("str", pounds, multiline)
    stack = [("code", 0)]

    def advance(k=1):
        nonlocal i, line, col
        for _ in range(k):
            if i < n and src[i] == "\n":
                line += 1
                col = 1
            else:
                col += 1
            i += 1

    while i < n:
        top = stack[-1]

        if top[0] == "code":
            ch = src[i]
            # Comments. Only in code; inside a string "//" is just text.
            if src.startswith("//", i):
                while i < n and src[i] != "\n":
                    advance()
                continue
            if src.startswith("/*", i):
                depth = 0
                while i < n:
                    if src.startswith("/*", i):
                        depth += 1
                        advance(2)
                        continue
                    if src.startswith("*/", i):
                        depth -= 1
                        advance(2)
                        if depth == 0:
                            break
                        continue
                    advance()
                continue
            # A string literal, with any number of leading pound signs (a raw string).
            if ch == "#" or ch == '"':
                j = i
                pounds = 0
                while j < n and src[j] == "#":
                    pounds += 1
                    j += 1
                if j < n and src[j] == '"':
                    multiline = src.startswith('"""', j)
                    quote_len = 3 if multiline else 1
                    advance((j - i) + quote_len)
                    stack.append(("str", pounds, multiline))
                    continue
                # A lone '#' that does not open a string: an attribute, a directive, a
                # keyword like #available. Step over the pounds and carry on.
                advance(max(1, pounds))
                continue
            # Character-level bookkeeping for an interpolation segment: it ends at the
            # paren that closes the one the interpolation opened with.
            if ch == "(":
                stack[-1] = ("code", top[1] + 1)
                advance()
                continue
            if ch == ")":
                if top[1] == 0 and len(stack) > 1:
                    stack.pop()  # end of \( ... ) -- back into the string
                    advance()
                    continue
                stack[-1] = ("code", max(0, top[1] - 1))
                advance()
                continue
            advance()
            continue

        # Inside a string literal.
        _, pounds, multiline = top
        escape = "\\" + "#" * pounds
        closer = ('"""' if multiline else '"') + "#" * pounds

        if src.startswith(escape, i):
            after = i + len(escape)
            if after < n and src[after] == "(":
                advance(len(escape) + 1)
                stack.append(("code", 0))
                continue
            # An ordinary escape: skip the backslash and whatever it escapes, so a
            # \" does not read as the end of the string.
            advance(len(escape) + (1 if after < n else 0))
            continue
        if src.startswith(closer, i):
            advance(len(closer))
            stack.pop()
            continue
        ch = src[i]
        if ch in DASHES:
            hits.append((line, col, ch))
        advance()

    return hits


def load_allowlist(path):
    """path -> set of trimmed source lines that are allowed to carry a dash."""
    allow = {}
    if not path or not os.path.exists(path):
        return allow
    with open(path, encoding="utf-8") as f:
        for raw in f:
            entry = raw.rstrip("\n")
            if not entry.strip() or entry.lstrip().startswith("#"):
                continue
            if "\t" not in entry:
                continue
            file_part, text = entry.split("\t", 1)
            allow.setdefault(file_part.strip(), set()).add(text.strip())
    return allow


def swift_files(roots):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            for name in sorted(filenames):
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("roots", nargs="*", default=[])
    ap.add_argument("--allowlist", default=DEFAULT_ALLOWLIST)
    ap.add_argument(
        "--print-allowlist",
        action="store_true",
        help="print every finding in allowlist format, to paste in after justifying it",
    )
    args = ap.parse_args(argv)
    roots = args.roots or ["app/Sources", "ios/Sources", "Shared"]

    allow = load_allowlist(args.allowlist)
    findings = []
    allowed = 0

    for path in swift_files(roots):
        try:
            with open(path, encoding="utf-8") as f:
                src = f.read()
        except (OSError, UnicodeDecodeError) as exc:
            print("%s: could not read (%s)" % (path, exc), file=sys.stderr)
            continue
        hits = scan_string_literals(src)
        if not hits:
            continue
        lines = src.splitlines()
        rel = os.path.relpath(path)
        # An entry may name the file the way the repo does (the normal case) or the way the
        # scan was invoked, which for a planted tree in scripts/test-lints.sh is an absolute
        # path outside the repo. Accept either, so the guard tests the same code the gate runs.
        keys = {rel, path, os.path.abspath(path)}
        allowed_here = set()
        for key in keys:
            allowed_here |= allow.get(key, set())
        for line, col, ch in hits:
            text = lines[line - 1].strip() if line - 1 < len(lines) else ""
            if text in allowed_here:
                allowed += 1
                continue
            findings.append((rel, line, col, ch, text))

    if args.print_allowlist:
        for rel, line, col, ch, text in findings:
            print("%s\t%s" % (rel, text))
        return 1 if findings else 0

    for rel, line, col, ch, text in findings:
        print("%s:%d:%d: %s in a user-facing string: %s" % (rel, line, col, DASHES[ch], text))

    if findings:
        print(
            "\n%d dash%s in %d string%s. Rewrite each sentence with the punctuation it wants\n"
            "(a period between two independent clauses, a colon before a definition,\n"
            "parentheses around an aside, a comma only for a tight one). If a dash is\n"
            "typography rather than prose, add it to %s with a line saying why."
            % (
                len(findings),
                "" if len(findings) == 1 else "es",
                len({(f[0], f[1]) for f in findings}),
                "" if len({(f[0], f[1]) for f in findings}) == 1 else "s",
                os.path.relpath(args.allowlist),
            ),
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
