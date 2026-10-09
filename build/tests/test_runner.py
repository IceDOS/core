from __future__ import annotations

import contextlib
import io
import os
import shutil
import subprocess
import tempfile
import unittest
import warnings
from pathlib import Path
from unittest import mock

from build.context import BuildEnv
from build.options import Options
from build.runner import build


class RunVmTest(unittest.TestCase):
    def setUp(self):
        # build() never closes its lock file; it is released when build() returns.
        _ = self.enterContext(warnings.catch_warnings())
        warnings.simplefilter("ignore", ResourceWarning)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        state_dir = root / ".state"
        state_dir.mkdir()
        _ = (state_dir / "flake.nix").write_text("{}")
        self.env = BuildEnv(
            root=root, config_root=root, state_dir=state_dir, inputs_prefix="icedos"
        )

    def run_vm(self, vm_rc: int) -> list[tuple[list[str], Path]]:
        calls: list[tuple[list[str], Path]] = []

        def fake_run(cmd: list[str], *, cwd: Path, check: bool, **_kwargs: object):
            calls.append((list(cmd), Path(cwd)))
            if cmd[0] == "nh":
                script = Path(cwd) / "result" / "bin" / "run-test-vm"
                script.parent.mkdir(parents=True)
                _ = script.write_text("")
                return subprocess.CompletedProcess(cmd, 0)
            return subprocess.CompletedProcess(cmd, vm_rc)

        with (
            mock.patch.dict(os.environ),
            mock.patch("build.runner.subprocess.run", side_effect=fake_run),
            mock.patch(
                "build.runner.os.execv", side_effect=AssertionError("exec'd the VM")
            ),
            mock.patch("build.runner.os.chdir"),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            try:
                build(self.env, Options(action="build-vm", run_vm=True))
            finally:
                self.addCleanup(shutil.rmtree, os.environ["ICEDOS_BUILD_DIR"], True)
        return calls

    def test_vm_runs_as_a_child_from_the_build_dir(self):
        calls = self.run_vm(0)
        self.assertEqual(len(calls), 2)
        build_dir = calls[0][1]
        script = str(build_dir / "result" / "bin" / "run-test-vm")
        self.assertEqual(calls[1], ([script], build_dir))

    def test_vm_exit_code_becomes_the_result(self):
        with self.assertRaises(SystemExit) as cm:
            _ = self.run_vm(3)
        self.assertEqual(cm.exception.code, 3)


if __name__ == "__main__":
    unittest.main()
