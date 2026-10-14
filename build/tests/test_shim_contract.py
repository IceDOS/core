from __future__ import annotations

import unittest
from pathlib import Path

from build.context import CONTEXT_ENV, HOOK_NAMES
from build.hooks import ORIG_PREFIX, RESTORED_VARS

# The shim is Nix, so a text check is what keeps the names on both sides in step.
REBUILD_NIX = Path(__file__).resolve().parents[2] / "modules" / "rebuild.nix"


class ShimContractTest(unittest.TestCase):
    def setUp(self):
        self.source = REBUILD_NIX.read_text()

    def test_shim_passes_the_context(self):
        self.assertIn(f"{CONTEXT_ENV}=", self.source)

    def test_shim_passes_every_original_the_hooks_get_back(self):
        for name in RESTORED_VARS:
            self.assertIn(f"{ORIG_PREFIX}{name}=", self.source)

    def test_context_names_every_hook(self):
        for name in HOOK_NAMES:
            self.assertIn(f'"{name}"', self.source)

    def test_help_is_the_shared_usage_file(self):
        self.assertIn("${../build/usage.txt}", self.source)


if __name__ == "__main__":
    unittest.main()
