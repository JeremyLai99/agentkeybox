#!/usr/bin/env python3
"""Offline regression tests for the release binary scanner; never launches an app."""
from pathlib import Path
import subprocess
import tempfile
import unittest

CHECKER = Path(__file__).with_name("check-release-qa-strings.sh").resolve()
NAMES = ("AgentKeyBox", "agentkeybox-mcp", "akb")
MARKERS = ("AGENTKEYBOX_QA_ID", "/private/tmp/akb-qa-", "dev.agentkeybox.qa.",
           "recovery-fixture.json", "submission-fixture.json", "PinnedRecoveryFixtureBrowser",
           "interrupt-card-save", "QA —", "AgentKeyBox QA", "Unable to open isolated preferences")


class ReleaseQAScannerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in NAMES:
            (self.root / name).write_bytes(b"synthetic clean binary\x00")

    def check(self):
        return subprocess.run([str(CHECKER), str(self.root)], capture_output=True).returncode

    def test_clean_binaries_pass(self):
        self.assertEqual(self.check(), 0)

    def test_every_missing_executable_fails(self):
        for name in NAMES:
            path = self.root / name
            path.unlink()
            self.assertNotEqual(self.check(), 0)
            path.write_bytes(b"synthetic clean binary")

    def test_every_marker_in_each_executable_fails(self):
        for name in NAMES:
            for marker in MARKERS:
                with self.subTest(name=name, marker=marker):
                    (self.root / name).write_bytes(b"\x00" + marker.encode() + b"\x00")
                    self.assertNotEqual(self.check(), 0)
            (self.root / name).write_bytes(b"synthetic clean binary")

    def test_utf16_markers_fail(self):
        for encoding in ("utf-16-le", "utf-16-be"):
            (self.root / NAMES[0]).write_bytes("QA —".encode(encoding))
            self.assertNotEqual(self.check(), 0)


if __name__ == "__main__":
    unittest.main()
