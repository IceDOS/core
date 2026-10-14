from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from build.context import BuildEnv
from build.options import Options
from build.update import validate_update_except

LOCK_FIXTURE = {
    "nodes": {
        "root": {
            "inputs": {
                "sub": "sub-node",
                "nixpkgs": "nixpkgs-node",
                "local": "local-node",
            }
        },
        "sub-node": {
            "inputs": {
                "nested": "nested-node",
            },
            "locked": {"type": "path", "path": "/nix/store/hash-sub-subflake"},
        },
        "nixpkgs-node": {"locked": {"type": "github", "rev": "1111"}},
        "local-node": {"locked": {"type": "path", "path": "/path"}},
        "nested-node": {"locked": {"type": "github", "rev": "2222"}},
    }
}


class ValidateUpdateExceptTest(unittest.TestCase):
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

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_missing_state_lock_warns_and_passes(self) -> None:
        opts = Options(update_except=["nixpkgs"])
        # Should not raise SystemExit
        validate_update_except(self.env, opts)

    def test_valid_root_nested_and_config_names_pass(self) -> None:
        (self.state_dir / "flake.lock").write_text(json.dumps(LOCK_FIXTURE))
        (self.config_root / "flake.lock").write_text(
            json.dumps({"nodes": {"root": {"inputs": {"icedos": "node"}}}})
        )

        opts = Options(update_except=["nixpkgs", "sub/nested", "icedos"])
        validate_update_except(self.env, opts)

    def test_subflake_root_exclusion_raises(self) -> None:
        (self.state_dir / "flake.lock").write_text(json.dumps(LOCK_FIXTURE))
        opts = Options(update_except=["sub"])
        with self.assertRaises(SystemExit):
            validate_update_except(self.env, opts)

    def test_unknown_name_raises(self) -> None:
        (self.state_dir / "flake.lock").write_text(json.dumps(LOCK_FIXTURE))
        opts = Options(update_except=["nonexistent"])
        with self.assertRaises(SystemExit):
            validate_update_except(self.env, opts)


class UpdateCachePinTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self.tmp.name)
        self.config_root = self.tmp_path / "config"
        self.config_root.mkdir()
        self.env = BuildEnv(
            root=self.tmp_path,
            config_root=self.config_root,
            state_dir=self.tmp_path / "state",
            inputs_prefix="icedos",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_name_nixpkgs_updates_pin_and_returns_kept(self) -> None:
        from unittest.mock import patch
        from build.update import update_cache_pin

        opts = Options(state_inputs=["nixpkgs"])
        with patch("build.update.run") as mock_run:
            result = update_cache_pin(self.env, opts, ["nixpkgs", "home-manager"])
            self.assertEqual(result, ["home-manager"])
            mock_run.assert_called_once_with(
                ["nix", "flake", "update", "icedos/cache-server", "--refresh"],
                cwd=self.config_root,
                check=True,
            )

    def test_name_both_updates_pin_and_returns_empty(self) -> None:
        from unittest.mock import patch
        from build.update import update_cache_pin

        opts = Options(state_inputs=["nixpkgs", "home-manager"])
        with patch("build.update.run") as mock_run:
            result = update_cache_pin(self.env, opts, ["nixpkgs", "home-manager"])
            self.assertEqual(result, [])
            mock_run.assert_called_once_with(
                ["nix", "flake", "update", "icedos/cache-server", "--refresh"],
                cwd=self.config_root,
                check=True,
            )

    def test_name_neither_runs_nothing(self) -> None:
        from unittest.mock import patch
        from build.update import update_cache_pin

        opts = Options(state_inputs=["other"])
        with patch("build.update.run") as mock_run:
            result = update_cache_pin(self.env, opts, ["nixpkgs", "home-manager"])
            self.assertEqual(result, [])
            mock_run.assert_not_called()

    def test_with_update_core_runs_nothing(self) -> None:
        from unittest.mock import patch
        from build.update import update_cache_pin

        opts = Options(state_inputs=["nixpkgs"], update_core=True)
        with patch("build.update.run") as mock_run:
            result = update_cache_pin(self.env, opts, ["nixpkgs", "home-manager"])
            self.assertEqual(result, [])
            mock_run.assert_not_called()


if __name__ == "__main__":
    unittest.main()

