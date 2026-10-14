from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

from build.context import BuildEnv, RebuildContext
from build.options import Options
from build.snapshot import (
    CONFIG_SET_MARKER,
    cache_files,
    config_set_changed,
    current_generation,
    latest_config_snapshot,
    record_generation,
    record_rebuild,
    snapshot_config_set,
    snapshot_folders,
    timestamp,
)

T1 = "2026-10-08T10:00:00+03:00"
T2 = "2026-10-08T11:00:00+03:00"
T3 = "2026-10-08T12:00:00+03:00"
DIRS = ("configs",)


class _CacheCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.config_root = self.root / "config"
        self.state_dir = self.config_root / ".state"
        self.cache_dir = self.state_dir / ".cache"
        self.state_dir.mkdir(parents=True)

    def write(self, rel: str, text: str) -> Path:
        path = self.config_root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        _ = path.write_text(text)
        return path

    def write_config_set(self) -> None:
        _ = self.write("config.toml", "a = 1\n")
        _ = self.write("configs/apps.toml", "b = 1\n")
        _ = self.write("configs/.private.toml", "c = 1\n")
        _ = self.write("configs/sub/deep.toml", "d = 1\n")
        _ = self.write("configs/notes.txt", "not a config\n")

    def snapshot(self, stamp: str) -> bool:
        folder = self.cache_dir / stamp
        return snapshot_config_set(self.cache_dir, folder, self.config_root, DIRS)


class SnapshotFoldersTest(_CacheCase):
    def test_only_timestamped_dirs_in_time_order(self):
        names = [
            "generations",
            "2026-10-25T03:30:00+02:00",
            "2026-10-25T03:45:00+03:00",
            "2026-10-08",
        ]
        for name in names:
            (self.cache_dir / name).mkdir(parents=True)
        _ = (self.cache_dir / "options-doc.json").write_text("{}")
        found = [p.name for p in snapshot_folders(self.cache_dir)]
        # 03:45+03:00 is 00:45 UTC, an hour before 03:30+02:00.
        self.assertEqual(
            found, ["2026-10-25T03:45:00+03:00", "2026-10-25T03:30:00+02:00"]
        )

    def test_missing_cache_dir_has_no_folders(self):
        self.assertEqual(snapshot_folders(self.cache_dir), [])

    def test_timestamp_has_the_date_Is_shape(self):
        stamp = timestamp()
        self.assertRegex(stamp, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$")
        self.assertIsNotNone(datetime.fromisoformat(stamp).tzinfo)


class ConfigSetTest(_CacheCase):
    def changed_after(self, mutate: Callable[[], object]) -> bool:
        self.write_config_set()
        self.assertTrue(self.snapshot(T1))
        _ = mutate()
        latest = latest_config_snapshot(self.cache_dir)
        return config_set_changed(latest, self.config_root, DIRS)

    def test_first_snapshot_copies_every_toml(self):
        self.write_config_set()
        self.assertTrue(self.snapshot(T1))
        folder = self.cache_dir / T1
        self.assertTrue((folder / CONFIG_SET_MARKER).is_file())
        for rel in (
            "config.toml",
            "configs/apps.toml",
            "configs/.private.toml",
            "configs/sub/deep.toml",
        ):
            self.assertEqual(
                (folder / rel).read_text(), (self.config_root / rel).read_text(), rel
            )
        self.assertFalse((folder / "configs/notes.txt").exists())

    def test_unchanged_set_is_not_snapshotted_again(self):
        self.write_config_set()
        self.assertTrue(self.snapshot(T1))
        self.assertFalse(self.snapshot(T2))
        self.assertFalse((self.cache_dir / T2).exists())

    def test_edit_is_a_change(self):
        self.assertTrue(
            self.changed_after(lambda: self.write("configs/apps.toml", "b = 2\n"))
        )

    def test_hidden_file_edit_is_a_change(self):
        self.assertTrue(
            self.changed_after(lambda: self.write("configs/.private.toml", "c = 2\n"))
        )

    def test_new_file_is_a_change(self):
        self.assertTrue(
            self.changed_after(lambda: self.write("configs/new.toml", "e = 1\n"))
        )

    def test_removed_file_is_a_change(self):
        self.assertTrue(
            self.changed_after((self.config_root / "configs/sub/deep.toml").unlink)
        )

    def test_removed_config_toml_is_a_change(self):
        self.assertTrue(self.changed_after((self.config_root / "config.toml").unlink))

    def test_untouched_set_is_no_change(self):
        self.assertFalse(self.changed_after(lambda: None))

    def test_no_config_toml_on_either_side_is_no_change(self):
        _ = self.write("configs/apps.toml", "b = 1\n")
        self.assertTrue(self.snapshot(T1))
        self.assertFalse((self.cache_dir / T1 / "config.toml").exists())
        self.assertFalse(self.snapshot(T2))

    def test_latest_snapshot_skips_folders_without_the_marker(self):
        self.write_config_set()
        _ = self.snapshot(T1)
        (self.cache_dir / T2).mkdir()
        _ = (self.cache_dir / T2 / "flake.lock.config").write_text("{}")
        self.assertEqual(latest_config_snapshot(self.cache_dir), self.cache_dir / T1)


class CacheFilesTest(_CacheCase):
    def cache(self, stamp: str) -> list[str]:
        files = [
            (self.config_root / "flake.lock", "flake.lock.config"),
            (self.config_root / "flake.nix", "flake.nix.config"),
        ]
        return cache_files(self.cache_dir, self.cache_dir / stamp, files)

    def test_caches_new_files_then_only_changed_ones(self):
        _ = self.write("flake.lock", "lock 1")
        _ = self.write("flake.nix", "nix 1")
        self.assertEqual(self.cache(T1), ["flake.lock.config", "flake.nix.config"])
        self.assertEqual(self.cache(T2), [])
        self.assertFalse((self.cache_dir / T2).exists())
        _ = self.write("flake.lock", "lock 2")
        self.assertEqual(self.cache(T3), ["flake.lock.config"])
        self.assertEqual(
            (self.cache_dir / T3 / "flake.lock.config").read_text(), "lock 2"
        )

    def test_compares_with_the_newest_copy_of_each_file(self):
        # Regression: the shell version diffed against `ls -dt */ | head -1`, usually
        # generations/, so every rebuild re-cached all four flake files.
        _ = self.write("flake.lock", "lock 1")
        _ = self.write("flake.nix", "nix 1")
        _ = self.cache(T1)
        _ = self.write("flake.lock", "lock 2")
        _ = self.cache(T2)
        record_generation(self.cache_dir, "7", T2)
        self.assertEqual(self.cache(T3), [])

    def test_missing_source_is_skipped(self):
        _ = self.write("flake.nix", "nix 1")
        self.assertEqual(self.cache(T1), ["flake.nix.config"])


class GenerationTest(_CacheCase):
    def test_reads_the_number_from_the_profile_link(self):
        profile = self.root / "system"
        profile.symlink_to("system-315-link")
        self.assertEqual(current_generation(profile), "315")

    def test_unexpected_or_missing_profile_gives_none(self):
        odd = self.root / "odd"
        odd.symlink_to("something-else")
        self.assertIsNone(current_generation(odd))
        self.assertIsNone(current_generation(self.root / "absent"))

    def test_pointer_holds_the_bare_folder_name(self):
        record_generation(self.cache_dir, "315", T1)
        self.assertEqual((self.cache_dir / "generations" / "315").read_text(), T1)


class RecordRebuildTest(_CacheCase):
    def setUp(self):
        super().setUp()
        self.write_config_set()
        _ = self.write("flake.lock", "config lock")
        _ = self.write("flake.nix", "config flake")
        _ = (self.state_dir / "flake.lock").write_text("state lock")
        _ = (self.state_dir / "flake.nix").write_text("state flake")
        self.profile = self.root / "system"
        self.profile.symlink_to("system-7-link")
        self.env = BuildEnv(
            root=self.root,
            config_root=self.config_root,
            state_dir=self.state_dir,
            inputs_prefix="icedos",
        )
        self.ctx = RebuildContext(config_dirs=DIRS, hooks={})

    def record(
        self, stamp: str, action: str = "switch", previous: str | None = None
    ) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            record_rebuild(
                self.env,
                Options(action=action),
                self.ctx,
                stamp=stamp,
                profile=self.profile,
                previous_generation=previous,
            )
        return out.getvalue()

    def test_switch_writes_one_folder_and_the_pointer(self):
        out = self.record(T1)
        names = "config set, flake.lock.config, flake.nix.config, flake.lock.state, flake.nix.state"
        self.assertEqual(out, f"> Caching {names}\n")
        self.assertEqual([p.name for p in snapshot_folders(self.cache_dir)], [T1])
        self.assertEqual((self.cache_dir / "generations" / "7").read_text(), T1)

    def test_nothing_changed_prints_nothing(self):
        _ = self.record(T1)
        self.assertEqual(self.record(T2), "")
        self.assertFalse((self.cache_dir / T2).exists())

    def test_build_writes_no_pointer(self):
        _ = self.record(T1, action="build")
        self.assertFalse((self.cache_dir / "generations").exists())

    def test_unmoved_profile_writes_no_pointer(self):
        _ = self.record(T1, previous="7")
        self.assertFalse((self.cache_dir / "generations").exists())

    def test_moved_profile_writes_the_pointer(self):
        _ = self.record(T1, previous="6")
        self.assertEqual((self.cache_dir / "generations" / "7").read_text(), T1)


if __name__ == "__main__":
    unittest.main()
