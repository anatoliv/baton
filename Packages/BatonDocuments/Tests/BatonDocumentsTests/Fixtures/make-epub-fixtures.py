#!/usr/bin/env python3
"""Builds the EPUB and zip fixtures for EPUBImporterTests with Python's own zipfile/zlib.

The point is that the archives come from an independent zip writer, so Baton's reader and
inflate are checked against bytes they did not produce. The text is made up. Deterministic:
fixed timestamps and a seeded generator, so re-running it changes nothing.

    python3 Packages/BatonDocuments/Tests/BatonDocumentsTests/Fixtures/make-epub-fixtures.py
"""
import os, random, zipfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
STAMP = (2026, 10, 3, 12, 0, 0)


def write(name, files, level=6):
    """files: list of (path, bytes-or-str, compress?)"""
    with zipfile.ZipFile(os.path.join(HERE, name), "w") as z:
        for path, data, compress in files:
            info = zipfile.ZipInfo(path, STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED if compress else zipfile.ZIP_STORED
            if isinstance(data, str):
                data = data.encode("utf-8")
            z.writestr(info, data, compresslevel=level if compress else None)


CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""


def xhtml(body, title="x"):
    return f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
<head><title>{title}</title><link rel="stylesheet" href="../style.css"/></head>
<body>{body}</body></html>"""


def para(n, words=40):
    rng = random.Random(n)
    vocab = "the machine hummed and the room was warm while she spoke of air ships and the sea".split()
    return " ".join(rng.choice(vocab) for _ in range(words)).capitalize() + "."


# EPUB 3: a navigation document in its own folder, two chapters in one file reached by anchors,
# a file the contents does not name (it continues chapter III), a percent-encoded file name, a
# non-linear notes file, a cover, a copyright page, drop caps and page numbers.
opf3 = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">urn:uuid:baton-fixture-3</dc:identifier>
    <dc:title>The Made-Up Machine</dc:title>
    <dc:creator id="a1">Writer, Jane Q.</dc:creator>
    <dc:language>en-GB</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav/toc.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="coverpage" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="title" href="text/title.xhtml" media-type="application/xhtml+xml"/>
    <item id="copy" href="text/copyright.xhtml" media-type="application/xhtml+xml"/>
    <item id="c12" href="text/chapter%201.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="text/c3.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3b" href="text/c3b.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="coverpage"/><itemref idref="title"/><itemref idref="copy"/>
    <itemref idref="c12"/><itemref idref="c3"/><itemref idref="c3b"/><itemref idref="notes" linear="no"/>
  </spine>
</package>"""
nav3 = xhtml("""<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
  <li><a href="../text/cover.xhtml">Cover</a></li>
  <li><a href="../text/copyright.xhtml">Copyright</a></li>
  <li><a href="../text/chapter%201.xhtml#ch1">Chapter I. The Air-Ship</a></li>
  <li><a href="../text/chapter%201.xhtml#ch2">Chapter II</a></li>
  <li><a href="../text/c3.xhtml">III. The Homeless</a></li>
</ol></nav><nav epub:type="landmarks"><ol><li><a href="../text/title.xhtml">Title</a></li></ol></nav>""")
chapter12 = xhtml(f"""
<section><h2 id="ch1">CHAPTER I.<br/>THE AIR-SHIP</h2>
<p><span class="dropcap"><img alt="I" src="../images/i.png"/></span>MAGINE, if you can, a small room.<span class="pagenum" epub:type="pagebreak" id="p1">1</span></p>
<p>{para(1)}</p></section>
<section><header><h2 id="ch2">CHAPTER II.</h2><h3>The Mending Apparatus</h3></header>
<p>{para(2)}</p><p>{para(3)}</p>
<pre><code>not = read</code></pre></section>""")
chapter3 = xhtml(f"""<h2>III</h2><h3>The Homeless</h3><p>{para(4)}</p>""")
chapter3b = xhtml(f"""<p>{para(5)}</p><p>The last sentence of the book.</p>""")
epub3 = [
    ("mimetype", "application/epub+zip", False),
    ("META-INF/container.xml", CONTAINER, True),
    ("OEBPS/content.opf", opf3, True),
    ("OEBPS/nav/toc.xhtml", nav3, True),
    ("OEBPS/images/cover.png", bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + b"not really a png", False),
    ("OEBPS/text/cover.xhtml", xhtml('<div><img src="../images/cover.png" alt="Cover"/></div>'), True),
    ("OEBPS/text/title.xhtml", xhtml("<h1>The Made-Up Machine</h1><p>by</p><p>Jane Q. Writer</p><p>London, 1909</p>"), True),
    ("OEBPS/text/copyright.xhtml", xhtml("<p>Copyright 1909 by Jane Q. Writer. All rights reserved by nobody at all, since this is made up.</p>"), True),
    ("OEBPS/text/chapter 1.xhtml", chapter12, True),
    ("OEBPS/text/c3.xhtml", chapter3, True),
    ("OEBPS/text/c3b.xhtml", chapter3b, True),
    ("OEBPS/text/notes.xhtml", xhtml("<p>A note that is not in the reading order.</p>"), True),
]
write("epub3-anchors.epub", epub3)

# EPUB 2: an NCX, one file per chapter, maximum compression, an OPF that prefixes its
# elements, and fonts obfuscated (which is not DRM and must still open).
opf2 = """<?xml version="1.0" encoding="UTF-8"?>
<opf:package xmlns:opf="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <opf:metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>An Older Book</dc:title><dc:creator opf:role="aut">Austen, Jane, 1775-1817</dc:creator><dc:language>en</dc:language>
    <opf:meta name="cover" content="cov"/>
  </opf:metadata>
  <opf:manifest>
    <opf:item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <opf:item id="cov" href="cover.jpg" media-type="image/jpeg"/>
    <opf:item id="one" href="one.html" media-type="application/xhtml+xml"/>
    <opf:item id="two" href="two.html" media-type="application/xhtml+xml"/>
  </opf:manifest>
  <opf:spine toc="ncx"><opf:itemref idref="one"/><opf:itemref idref="two"/></opf:spine>
</opf:package>"""
ncx = """<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
<navPoint id="n1" playOrder="1"><navLabel><text>Chapter 1</text></navLabel><content src="one.html"/></navPoint>
<navPoint id="n2" playOrder="2"><navLabel><text>Chapter 2</text></navLabel><content src="two.html"/>
  <navPoint id="n2a" playOrder="3"><navLabel><text>A Section</text></navLabel><content src="two.html#s"/></navPoint>
</navPoint></navMap></ncx>"""
encryption = """<?xml version="1.0"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
<enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
<enc:CipherData><enc:CipherReference URI="OEBPS/font.otf"/></enc:CipherData></enc:EncryptedData></encryption>"""
long_text = "\n".join(f"<p>{para(10 + i, 120)}</p>" for i in range(40))
epub2 = [
    ("mimetype", "application/epub+zip", False),
    ("META-INF/container.xml", CONTAINER, True),
    ("META-INF/encryption.xml", encryption, True),
    ("OEBPS/content.opf", opf2, True),
    ("OEBPS/toc.ncx", ncx, True),
    ("OEBPS/cover.jpg", b"\xff\xd8\xff not really a jpeg", False),
    ("OEBPS/one.html", xhtml(f"<h1>Chapter 1</h1>{long_text}"), True),
    ("OEBPS/two.html", xhtml(f"<h1>Chapter 2</h1><p>{para(99)}</p><h2 id='s'>A Section</h2><p>{para(98)}</p>"), True),
]
write("epub2-ncx.epub", epub2, level=9)

# Protected: content encrypted with AES. Baton refuses it rather than reading it.
drm_encryption = encryption.replace("http://www.idpf.org/2008/embedding", "http://www.w3.org/2001/04/xmlenc#aes128-cbc").replace("font.otf", "one.html")
write("protected.epub", [e for e in epub2 if e[0] != "META-INF/encryption.xml"] + [("META-INF/encryption.xml", drm_encryption, True)])

# Inflate under every kind of block zlib writes: stored (level 0, and incompressible data at
# any level), fixed Huffman (short input), dynamic Huffman (long text), long matches and
# distances (repeats far apart), and an empty file.
rng = random.Random(7)
noise = bytes(rng.getrandbits(8) for _ in range(20000))
prose = (" ".join(para(i, 60) for i in range(300))).encode()
far = noise[:3000] + prose[:5000] + noise[:3000]
cases = [("empty.bin", b""), ("short.txt", b"Hi."), ("prose.txt", prose), ("noise.bin", noise), ("far.bin", far),
         ("runs.bin", b"a" * 70000 + b"b" * 3 + b"a" * 258)]
for level in (0, 1, 6, 9):
    # Level 0 stores everything, so it gets the small cases only: it tests stored blocks, and
    # the large ones would only make the fixture large.
    chosen = [(n, d[:20000], True) for n, d in cases] if level == 0 else [(n, d, True) for n, d in cases]
    write(f"inflate-level{level}.zip", chosen, level=level)
print("written to", HERE)
