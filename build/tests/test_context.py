from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from build.context import CONTEXT_ENV, HOOK_NAMES, RebuildContext, load_rebuild_context


class LoadRebuildContextTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def load(self, payload: object) -> RebuildContext | None:
        path = self.dir / "context.json"
        text = payload if isinstance(payload, str) else json.dumps(payload)
        _ = path.write_text(text)
        with contextlib.redirect_stderr(io.StringIO()):
            return load_rebuild_context({CONTEXT_ENV: str(path)})

    def test_unset_or_empty_variable_means_raw_mode(self):
        self.assertIsNone(load_rebuild_context({}))
        self.assertIsNone(load_rebuild_context({CONTEXT_ENV: ""}))

    def test_reads_config_dirs_and_hooks(self):
        ctx = self.load(
            {
                "version": 1,
                "configDirs": ["configs", "hosts"],
                "hooks": {"preRebuild": ["/nix/store/a-hook"], "postUpdate": []},
            }
        )
        assert ctx is not None
        self.assertEqual(ctx.config_dirs, ("configs", "hosts"))
        self.assertEqual(ctx.hook_scripts("preRebuild"), ("/nix/store/a-hook",))
        self.assertEqual(ctx.hook_scripts("postUpdate"), ())

    def test_missing_keys_get_defaults(self):
        ctx = self.load({})
        assert ctx is not None
        self.assertEqual(ctx.config_dirs, ("configs",))
        for name in HOOK_NAMES:
            self.assertEqual(ctx.hook_scripts(name), ())

    def test_unknown_keys_are_ignored(self):
        ctx = self.load({"version": 9, "future": True, "hooks": {"preGc": ["/x"]}})
        assert ctx is not None
        self.assertEqual(ctx.hook_scripts("preGc"), ())

    def test_leading_slash_stays_inside_the_config_root(self):
        ctx = self.load({"configDirs": ["/configs", ""]})
        assert ctx is not None
        self.assertEqual(ctx.config_dirs, ("configs",))

    def test_unreadable_file_exits(self):
        missing = str(self.dir / "missing.json")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            _ = load_rebuild_context({CONTEXT_ENV: missing})

    def test_malformed_json_exits(self):
        with self.assertRaises(SystemExit):
            _ = self.load("{not json")

    def test_wrong_types_exit(self):
        payloads: list[object] = [
            [],
            {"configDirs": "configs"},
            {"hooks": []},
            {"hooks": {"preRebuild": "/x"}},
            {"hooks": {"preRebuild": [1]}},
        ]
        for payload in payloads:
            with self.subTest(payload=payload), self.assertRaises(SystemExit):
                _ = self.load(payload)


if __name__ == "__main__":
    unittest.main()
