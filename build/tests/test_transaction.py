from __future__ import annotations

from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from build.context import BuildEnv
from build.main import main
from build.options import Options
from build.transaction import Transaction, keep_after_failure
from build.util import write_text


class TransactionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.config_root = self.tmp_path / "config"
        self.state_dir = self.tmp_path / "state"
        self.config_root.mkdir()
        self.state_dir.mkdir()
        self.env = BuildEnv(
            root=self.tmp_path,
            config_root=self.config_root,
            state_dir=self.state_dir,
            inputs_prefix="icedos",
        )
        self.profile = self.tmp_path / "profile"
        self.profile.write_text("gen-1")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_begin_modify_rollback_restores_byte_for_byte(self) -> None:
        config_lock = self.config_root / "flake.lock"
        state_nix = self.state_dir / "flake.nix"
        state_lock = self.state_dir / "flake.lock"

        config_lock.write_text("config-orig")
        state_nix.write_text("nix-orig")
        state_lock.write_text("lock-orig")

        txn = Transaction.for_env(self.env, profile_path=str(self.profile))
        txn.begin()

        config_lock.write_text("config-modified")
        state_nix.write_text("nix-modified")
        state_lock.write_text("lock-modified")

        txn.finish(ok=False, action="build", remote_target=False)

        self.assertEqual(config_lock.read_text(), "config-orig")
        self.assertEqual(state_nix.read_text(), "nix-orig")
        self.assertEqual(state_lock.read_text(), "lock-orig")
        self.assertFalse((self.state_dir / ".txn").exists())

    def test_file_absent_at_begin_is_deleted_on_rollback(self) -> None:
        state_lock = self.state_dir / "flake.lock"
        self.assertFalse(state_lock.exists())

        txn = Transaction.for_env(self.env, profile_path=str(self.profile))
        txn.begin()

        state_lock.write_text("newly-created")
        txn.finish(ok=False, action="build", remote_target=False)

        self.assertFalse(state_lock.exists())

    def test_commit_keeps_new_contents_and_removes_txn(self) -> None:
        state_nix = self.state_dir / "flake.nix"
        state_nix.write_text("old")

        txn = Transaction.for_env(self.env, profile_path=str(self.profile))
        txn.begin()

        state_nix.write_text("new")
        txn.finish(ok=True, action="build", remote_target=False)

        self.assertEqual(state_nix.read_text(), "new")
        self.assertFalse((self.state_dir / ".txn").exists())

    def test_stale_txn_with_manifest_is_rolled_back_by_next_begin(self) -> None:
        state_nix = self.state_dir / "flake.nix"
        state_nix.write_text("old")

        txn1 = Transaction.for_env(self.env, profile_path=str(self.profile))
        txn1.begin()
        state_nix.write_text("modified-crash")
        # Simulate crash before finish: close lock file so another txn can run
        if txn1._lock_file:
            txn1._lock_file.close()
            txn1._lock_file = None

        txn2 = Transaction.for_env(self.env, profile_path=str(self.profile))
        txn2.begin()
        # When txn2 begins, it should have rolled back the stale txn1
        self.assertEqual(state_nix.read_text(), "old")
        txn2.finish(ok=True, action="build", remote_target=False)

    def test_stale_txn_without_manifest_is_removed_without_touching_files(self) -> None:
        state_nix = self.state_dir / "flake.nix"
        state_nix.write_text("current")

        txn_dir = self.state_dir / ".txn"
        txn_dir.mkdir()
        (txn_dir / "junk").write_text("junk")

        txn = Transaction.for_env(self.env, profile_path=str(self.profile))
        txn.begin()
        self.assertEqual(state_nix.read_text(), "current")
        txn.finish(ok=True, action="build", remote_target=False)

    def test_second_begin_while_first_holds_flock_exits(self) -> None:
        txn1 = Transaction.for_env(self.env, profile_path=str(self.profile))
        txn1.begin()

        txn2 = Transaction.for_env(self.env, profile_path=str(self.profile))
        with self.assertRaises(SystemExit) as ctx:
            txn2.begin()
        self.assertEqual(ctx.exception.code, 1)
        txn1.finish(ok=True, action="build", remote_target=False)

    def test_keep_after_failure_truth_table(self) -> None:
        self.assertTrue(keep_after_failure("switch", "gen-1", "gen-2", False))
        self.assertTrue(keep_after_failure("boot", "gen-1", "gen-2", False))
        self.assertFalse(keep_after_failure("switch", "gen-1", "gen-1", False))
        self.assertFalse(keep_after_failure("boot", "gen-1", "gen-1", False))
        self.assertFalse(keep_after_failure("build", "gen-1", "gen-2", False))
        self.assertFalse(keep_after_failure("build-vm", "gen-1", "gen-2", False))
        self.assertFalse(keep_after_failure("test", "gen-1", "gen-2", False))
        self.assertFalse(keep_after_failure("switch", "gen-1", "gen-2", True))
        self.assertFalse(keep_after_failure("boot", "gen-1", "gen-2", True))

    def test_write_text_leaves_no_icedos_tmp(self) -> None:
        target = self.state_dir / "test.txt"
        write_text(target, "atomic content")
        self.assertEqual(target.read_text(), "atomic content")
        self.assertFalse((self.state_dir / "test.txt.icedos-tmp").exists())

    @patch("build.main.from_environment")
    @patch("build.main._reported_rebuild")
    def test_main_transaction_rollback_and_commit(self, mock_run, mock_env) -> None:
        mock_env.return_value = self.env
        state_nix = self.state_dir / "flake.nix"
        state_nix.write_text("initial")

        # 1. RuntimeError rolls back
        mock_run.side_effect = RuntimeError("boom")
        with self.assertRaises(RuntimeError):
            main(["--build"])
        self.assertEqual(state_nix.read_text(), "initial")

        # 2. SystemExit(1) rolls back
        mock_run.side_effect = SystemExit(1)
        with self.assertRaises(SystemExit):
            main(["--build"])
        self.assertEqual(state_nix.read_text(), "initial")

        # 3. SystemExit(0) commits
        def modify_and_succeed(*_args, **_kwargs):
            state_nix.write_text("updated")
            return 0

        mock_run.side_effect = modify_and_succeed
        main(["--build"])
        self.assertEqual(state_nix.read_text(), "updated")

        # 4. KeyboardInterrupt rolls back
        state_nix.write_text("before-interrupt")
        def modify_and_interrupt(*_args, **_kwargs):
            state_nix.write_text("during-interrupt")
            raise KeyboardInterrupt()

        mock_run.side_effect = modify_and_interrupt
        with self.assertRaises(KeyboardInterrupt):
            main(["--build"])
        self.assertEqual(state_nix.read_text(), "before-interrupt")

    @patch("build.main.from_environment")
    @patch("build.main._reported_rebuild")
    def test_main_genflake_only_and_lock_only(self, mock_run, mock_env) -> None:
        mock_env.return_value = self.env
        state_nix = self.state_dir / "flake.nix"
        state_nix.write_text("original")

        # --genflake-only with rc=0 rolls back (persist is False)
        def modify_and_succeed(*_args, **_kwargs):
            state_nix.write_text("dry-change")
            return 0

        mock_run.side_effect = modify_and_succeed
        rc = main(["--genflake-only"])
        self.assertEqual(rc, 0)
        self.assertEqual(state_nix.read_text(), "original")

        # --lock-only with rc=0 commits
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = main(["--update", "--lock-only"])
        self.assertEqual(rc, 0)
        self.assertEqual(state_nix.read_text(), "dry-change")
        self.assertIn("inputs updated and kept", buf.getvalue())

        # --lock-only with re-exec child exit 0 writes marker and reports
        def child_reexec_exit_0(*_args, **_kwargs):
            state_nix.write_text("child-change")
            raise SystemExit(0)

        mock_run.side_effect = child_reexec_exit_0
        buf2 = io.StringIO()
        with redirect_stdout(buf2):
            rc = main(["--update", "--lock-only"])
        self.assertEqual(rc, 0)
        self.assertEqual(state_nix.read_text(), "child-change")
        self.assertTrue((self.state_dir / ".update-pending").exists())
        self.assertIn("inputs updated and kept", buf2.getvalue())

    def test_original_lock(self) -> None:
        state_lock = self.state_dir / "flake.lock"
        state_lock.write_text('{"nodes": {"root": "original"}}')

        txn = Transaction.for_env(self.env, profile_path=str(self.profile))
        self.assertEqual(txn.original_lock("state"), {})

        txn.begin()
        state_lock.write_text('{"nodes": {"root": "modified"}}')
        self.assertEqual(
            txn.original_lock("state"), {"nodes": {"root": "original"}}
        )
        self.assertEqual(txn.original_lock("config"), {})
        txn.finish(ok=True, action="build", remote_target=False)


if __name__ == "__main__":
    unittest.main()
