from __future__ import annotations

import contextlib
import io
import os
import unittest
from collections.abc import Callable
from pathlib import Path
from unittest import mock

from build import main as build_main
from build.context import BuildEnv, RebuildContext

STATE_DIR = Path("/cfg/.state")
ENV = BuildEnv(
    root=Path("/core"),
    config_root=Path("/cfg"),
    state_dir=STATE_DIR,
    inputs_prefix="icedos",
)
CTX = RebuildContext(config_dirs=("configs",), hooks={})


class _Run:
    def __init__(self) -> None:
        self.calls: list[str] = []
        self.hook_cwds: set[Path] = set()
        self.rc: int | None = None
        self.out = ""
        self.err = ""
        self.exc: Exception | None = None

    def step(self, label: str) -> Callable[..., None]:
        def fake(*_args: object, **_kwargs: object) -> None:
            self.calls.append(label)

        return fake

    def hooks(
        self, _ctx: RebuildContext, name: str, *, cwd: Path, hooks_only: bool = False
    ) -> None:
        self.calls.append(f"{name} (hooks only)" if hooks_only else name)
        self.hook_cwds.add(cwd)


def _main(
    argv: list[str],
    ctx: RebuildContext | None,
    *,
    build_exit: int | None = None,
    build_error: Exception | None = None,
    record_interrupt: bool = False,
    run: _Run | None = None,
) -> _Run:
    if run is None:
        run = _Run()

    def fake_build(*_args: object) -> None:
        run.calls.append("build")
        if build_exit is not None:
            raise SystemExit(build_exit)
        if build_error is not None:
            raise build_error

    def fake_record(*_args: object, **_kwargs: object) -> None:
        run.calls.append("record")
        if record_interrupt:
            raise KeyboardInterrupt

    fakes: dict[str, object] = {
        "load_rebuild_context": lambda _environ: ctx,
        "from_environment": lambda: ENV,
        "_nix_config": lambda _opts: build_main.BASE_NIX_CONFIG,
        "refresh_config_root_paths": run.step("refresh"),
        "maybe_re_exec_update_core": run.step("self-update"),
        "generate_flake": run.step("genflake"),
        "prepare_lock": run.step("lock"),
        "build": fake_build,
        "run_hooks": run.hooks,
        "record_rebuild": fake_record,
        "current_generation": lambda: None,
        "offer_reboot": run.step("reboot"),
    }
    out, err = io.StringIO(), io.StringIO()
    with contextlib.ExitStack() as stack:
        _ = stack.enter_context(mock.patch.dict(os.environ))
        for name, fake in fakes.items():
            _ = stack.enter_context(mock.patch.object(build_main, name, fake))
        _ = stack.enter_context(contextlib.redirect_stdout(out))
        _ = stack.enter_context(contextlib.redirect_stderr(err))
        try:
            run.rc = build_main.main(argv)
        except SystemExit as exc:
            run.rc = exc.code if isinstance(exc.code, int) else 1
        finally:
            run.out, run.err = out.getvalue(), err.getvalue()
    return run


class MainFlowTest(unittest.TestCase):
    def test_raw_mode_only_generates_locks_and_builds(self):
        run = _main([], None)
        self.assertEqual(
            run.calls, ["refresh", "self-update", "genflake", "lock", "build"]
        )
        self.assertEqual(run.rc, 0)

    def test_switch_runs_hooks_and_post_build_phases(self):
        run = _main([], CTX)
        self.assertEqual(
            run.calls,
            [
                "refresh",
                "self-update",
                "preRebuild",
                "genflake",
                "lock",
                "build",
                "record",
                "postRebuild",
                "reboot",
            ],
        )
        self.assertEqual(run.hook_cwds, {STATE_DIR})

    def test_update_runs_hooks_after_the_self_update(self):
        run = _main(["--update"], CTX)
        self.assertEqual(
            run.calls,
            [
                "refresh",
                "self-update",
                "preRebuild",
                "preUpdate",
                "genflake",
                "lock",
                "build",
                "postUpdate",
                "record",
                "postRebuild",
                "reboot",
            ],
        )

    def test_dry_runs_no_hooks(self):
        run = _main(["--dry"], CTX)
        self.assertEqual(run.calls, ["refresh", "self-update", "genflake", "lock"])
        self.assertIn("dry run — generating flake...", run.out)
        self.assertIn(
            "dry run — flake generated and inputs locked (module eval not checked)",
            run.out,
        )

    def test_genflake_only_runs_no_hooks_and_prints_nothing(self):
        run = _main(["--genflake-only"], CTX)
        self.assertEqual(run.calls, ["refresh", "self-update", "genflake", "lock"])
        self.assertEqual(run.out, "")

    def test_update_hooks_skips_everything_else(self):
        run = _main(["--update-hooks", "--update"], CTX)
        self.assertEqual(
            run.calls, ["preUpdate (hooks only)", "postUpdate (hooks only)"]
        )
        self.assertEqual(run.rc, 0)

    def test_update_hooks_without_context_warns(self):
        run = _main(["--update-hooks"], None)
        self.assertEqual(run.calls, [])
        self.assertEqual(run.rc, 0)
        self.assertIn("no rebuild hooks available here", run.err)

    def test_failed_build_is_reported_and_stops(self):
        run = _main([], CTX, build_exit=3)
        self.assertEqual(run.calls[-1], "build")
        self.assertEqual(run.rc, 3)
        self.assertIn("error: build failed with exit code 3", run.out)

    def test_interrupt_is_not_reported_as_a_failure(self):
        run = _main([], CTX, build_exit=130)
        self.assertEqual(run.rc, 130)
        self.assertNotIn("build failed", run.out)

    def test_raw_mode_failure_prints_nothing_extra(self):
        run = _main([], None, build_exit=3)
        self.assertEqual(run.rc, 3)
        self.assertEqual(run.out, "")

    def test_unexpected_exception_is_reported_and_re_raised(self):
        run = _Run()
        with self.assertRaises(RuntimeError):
            _ = _main([], CTX, build_error=RuntimeError("boom"), run=run)
        self.assertIn("error: build failed with exit code 1", run.out)

    def test_interrupt_during_snapshot_reports_after_build(self):
        run = _main([], CTX, record_interrupt=True)
        self.assertEqual(run.rc, 130)
        self.assertIn("interrupted after build", run.err)


if __name__ == "__main__":
    unittest.main()
