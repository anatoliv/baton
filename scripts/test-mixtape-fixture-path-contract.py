#!/usr/bin/env python3
"""CPU host Foundation/Darwin boundary check; not compiled Swift/simulator proof."""
import ctypes
from pathlib import Path
import sys
import tempfile
import unittest
from Foundation import NSURL

LEGACY='--legacy' in sys.argv
if LEGACY: sys.argv.remove('--legacy')
LIB=ctypes.CDLL(None)
LIB.realpath.argtypes=[ctypes.c_char_p,ctypes.c_void_p]
LIB.realpath.restype=ctypes.c_void_p
LIB.free.argtypes=[ctypes.c_void_p]

def path_admitted(path):
    selected=NSURL.fileURLWithPath_(str(path))
    if LEGACY:
        normalized=selected.URLByStandardizingPath()
        return (str(normalized.path()).startswith('/private/tmp/') and
                normalized==normalized.URLByResolvingSymlinksInPath())
    lexical=str(selected.path())
    if not lexical.startswith('/private/tmp/'): return False
    resolved=LIB.realpath(lexical.encode(),None)
    if not resolved: return False
    try: return ctypes.string_at(resolved).decode()==lexical
    finally: LIB.free(resolved)

class FixturePathContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(dir='/private/tmp')
        self.root=Path(self.temporary.name)
        self.file=self.root/'synthetic.json'
        self.file.write_bytes(b'{}'); self.file.chmod(0o600)
    def tearDown(self): self.temporary.cleanup()

    def test_exact_retained_synthetic_fixture_is_admitted(self):
        self.assertTrue(path_admitted('/private/tmp/baton-tbx-9252-mp3-20261007/media.json'))
    def test_canonical_private_file_is_admitted(self):
        self.assertTrue(path_admitted(self.file))
    def test_unexpected_tmp_alias_input_is_rejected(self):
        self.assertFalse(path_admitted(str(self.file).replace('/private/tmp/','/tmp/',1)))
    def test_dot_component_is_rejected(self):
        self.assertFalse(path_admitted(str(self.root)+'/./synthetic.json'))
    def test_parent_traversal_is_rejected(self):
        self.assertFalse(path_admitted(str(self.root)+'/../'+self.root.name+'/synthetic.json'))
    def test_file_symlink_inside_private_root_is_rejected(self):
        link=self.root/'link.json'; link.symlink_to(self.file)
        self.assertFalse(path_admitted(link))
    def test_symlink_escape_is_rejected(self):
        link=self.root/'outside.json'; link.symlink_to('/dev/null')
        self.assertFalse(path_admitted(link))
    def test_directory_symlink_is_rejected(self):
        folder=self.root/'media';folder.mkdir(); file=folder/'synthetic.json';file.write_bytes(b'{}')
        link=self.root/'alias';link.symlink_to(folder)
        self.assertFalse(path_admitted(link/'synthetic.json'))

if __name__=='__main__': unittest.main()
