from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from build.context import CONTEXT_ENV, RebuildContext
from build.hooks import hook_env, run_hooks

_BASE = {
    "PATH": "/build/bin:/usr/bin",
    "PYTHONPATH": "/nix/store/core",
    "NIX_CONFIG": "access-tokens = github.com=secret",
    "ICEDOS_GITHUB_TOKEN": "secret",
    "skip_update_core": "1",
    CONTEXT_ENV: "/nix/store/context.json",
    "ICEDOS_ORIG_PATH": "/usr/bin",
    "ICEDOS_ORIG_PYTHONPATH": "",
    "ICEDOS_ORIG_NIX_CONFIG": "",
    "ICEDOS_STATE_DIR": "/cfg/.state",
}

# Hooks are Python scripts, so the test needs no shell in the build sandbox.
_HOOK = """\
#!{python}
import os
fields = [
    {label!r},
    os.getcwd(),
    os.environ.get("ICEDOS_GITHUB_TOKEN", "-"),
    os.environ.get("ICEDOS_HOOKS_ONLY", "-"),
]
with open({log!r}, "a") as log:
    log.write(" ".join(fields) + "\\n")
raise SystemExit({code})
"""


class HookEnvTest(unittest.TestCase):
    def test_drops_the_token_and_internal_variables(self):
        env = hook_env(_BASE, hooks_only=False)
        for name in ("ICEDOS_GITHUB_TOKEN", "skip_update_core", CONTEXT_ENV):
            self.assertNotIn(name, env)
        self.assertFalse(any(key.startswith("ICEDOS_ORIG_") for key in env))

    def test_restores_the_invoking_shell_values(self):
        env = hook_env(_BASE, hooks_only=False)
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertNotIn("PYTHONPATH", env)
        self.assertNotIn("NIX_CONFIG", env)

    def test_keeps_the_users_own_nix_config(self):
        env = hook_env(
            {**_BASE, "ICEDOS_ORIG_NIX_CONFIG": "cores = 4"}, hooks_only=False
        )
        self.assertEqual(env["NIX_CONFIG"], "cores = 4")

    def test_nix_config_never_survives_without_an_original(self):
        base = {k: v for k, v in _BASE.items() if not k.startswith("ICEDOS_ORIG_")}
        env = hook_env(base, hooks_only=False)
        self.assertNotIn("NIX_CONFIG", env)
        self.assertEqual(env["PATH"], "/build/bin:/usr/bin")

    def test_hooks_only_flag(self):
        self.assertEqual(hook_env(_BASE, hooks_only=True)["ICEDOS_HOOKS_ONLY"], "1")
        self.assertNotIn("ICEDOS_HOOKS_ONLY", hook_env(_BASE, hooks_only=False))

    def test_passes_everything_else_through(self):
        env = hook_env(_BASE, hooks_only=False)
        self.assertEqual(env["ICEDOS_STATE_DIR"], "/cfg/.state")


class RunHooksTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name).resolve()
        self.log = self.dir / "log"

    def hook(self, label: str, code: int = 0) -> str:
        path = self.dir / f"hook-{label}"
        script = _HOOK.format(
            python=sys.executable, label=label, log=str(self.log), code=code
        )
        _ = path.write_text(script)
        path.chmod(0o755)
        return str(path)

    def run_hooks(
        self, hooks: dict[str, tuple[str, ...]], name: str, **kwargs: bool
    ) -> str:
        ctx = RebuildContext(config_dirs=("configs",), hooks=hooks)
        err = io.StringIO()
        with mock.patch.dict(os.environ, _BASE), contextlib.redirect_stderr(err):
            run_hooks(ctx, name, cwd=self.dir, **kwargs)
        return err.getvalue()

    def lines(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []

    def labels(self) -> list[str]:
        return [line.split()[0] for line in self.lines()]

    def test_runs_in_order_in_cwd_without_the_token(self):
        _ = self.run_hooks(
            {"preRebuild": (self.hook("a"), self.hook("b"))}, "preRebuild"
        )
        self.assertEqual(self.lines(), [f"a {self.dir} - -", f"b {self.dir} - -"])

    def test_a_failing_hook_warns_and_the_next_one_runs(self):
        hooks = {"postRebuild": (self.hook("bad", code=3), self.hook("good"))}
        err = self.run_hooks(hooks, "postRebuild")
        self.assertEqual(self.labels(), ["bad", "good"])
        self.assertIn("postRebuild hook 0 exited with code 3", err)

    def test_a_missing_script_warns_and_the_next_one_runs(self):
        hooks = {"preUpdate": (str(self.dir / "gone"), self.hook("next"))}
        err = self.run_hooks(hooks, "preUpdate")
        self.assertEqual(self.labels(), ["next"])
        self.assertIn("preUpdate hook 0 could not start", err)

    def test_hooks_only_reaches_the_hook(self):
        _ = self.run_hooks(
            {"preUpdate": (self.hook("h"),)}, "preUpdate", hooks_only=True
        )
        self.assertEqual(self.lines(), [f"h {self.dir} - 1"])

    def test_no_hooks_is_a_no_op(self):
        self.assertEqual(self.run_hooks({}, "preRebuild"), "")
        self.assertEqual(self.lines(), [])

    def test_ctrl_c_stops_with_130(self):
        ctx = RebuildContext(config_dirs=("configs",), hooks={"preRebuild": ("/x",)})
        with (
            mock.patch("build.hooks.subprocess.run", side_effect=KeyboardInterrupt),
            contextlib.redirect_stderr(io.StringIO()) as err,
            self.assertRaises(SystemExit) as cm,
        ):
            run_hooks(ctx, "preRebuild", cwd=self.dir)
        self.assertEqual(cm.exception.code, 130)
        self.assertIn("interrupted during preRebuild hook 0", err.getvalue())


if __name__ == "__main__":
    unittest.main()
