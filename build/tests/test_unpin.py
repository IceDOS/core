from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from build.context import BuildEnv
from build.genflake import CachePin, cache_unpin_info
from build.options import Options
from build.update import (
    CACHE_UNPIN_FILE,
    _cache_time,
    _flake_metadata,
    _rollback_note,
    load_unpins,
    prepare_unpins,
    update_cache_pin,
)

NIXPKGS_REV = "c" * 40
HM_REV = "d" * 40
FOO_REV = "e" * 40
PINS = {
    "nixpkgs": CachePin(
        "github:nixos/nixpkgs", "github:nixos/nixpkgs/nixos-unstable", NIXPKGS_REV, 2000
    ),
    "home-manager": CachePin(
        "github:nix-community/home-manager",
        "github:nix-community/home-manager/master",
        HM_REV,
        3000,
    ),
    "apps/foo": CachePin("github:icedos/foo", "github:icedos/foo/main", FOO_REV, None),
}
# Latest upstream (resolved with --refresh against latestUrl), newer than the cache.
LATEST = {
    "github:nixos/nixpkgs/nixos-unstable": ("a" * 40, 5000),
    "github:nix-community/home-manager/master": ("b" * 40, 6000),
    "github:icedos/foo/main": ("f" * 40, 7000),
}
# Dates of the cache's own revs, for the fallback lookup when genflake has none.
REV_DATES = {FOO_REV: 4000}
UNKNOWN_REV = "z" * 40


class _Env(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.config_root = root / "config"
        self.state_dir = root / "state"
        self.config_root.mkdir()
        self.state_dir.mkdir()
        self.env = BuildEnv(
            root=root,
            config_root=self.config_root,
            state_dir=self.state_dir,
            inputs_prefix="icedos",
        )
        self.path = self.state_dir / CACHE_UNPIN_FILE

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def entries(self) -> dict[str, object]:
        data = json.loads(self.path.read_text())
        assert isinstance(data, dict)
        return data

    def write_entries(self, data: object) -> None:
        self.path.write_text(json.dumps(data))

    def prepare(
        self,
        opts: Options | None = None,
        *,
        pins: dict[str, CachePin] | None = None,
        latest: dict[str, tuple[str, int]] | None = None,
        failing: frozenset[str] = frozenset(),
    ) -> str:
        pins = PINS if pins is None else pins
        latest = LATEST if latest is None else latest
        err = io.StringIO()

        def fake_capture(cmd: list[str], **_kwargs: object) -> str:
            url = cmd[-1]
            if url in failing:
                raise SystemExit(1)
            if url in latest:
                rev, mtime = latest[url]
            else:
                rev = url.rsplit("/", 1)[-1]
                mtime = REV_DATES[rev]
            return json.dumps({"locked": {"rev": rev, "lastModified": mtime}})

        with (
            patch("build.update.cache_unpin_info", return_value=dict(pins)),
            patch("build.update.capture", side_effect=fake_capture),
            contextlib.redirect_stderr(err),
        ):
            prepare_unpins(self.env, opts or Options(), [])
        return err.getvalue()


class LoadTest(_Env):
    def test_missing_file_is_empty(self):
        self.assertEqual(load_unpins(self.env), ({}, False))

    # A file Python cannot use must degrade to "no unpins" and ask for a rewrite:
    # genflake would apply whatever survived, so aborting here blocks every build.
    def test_corrupt_file_is_dropped_with_a_warning(self):
        self.path.write_text("{not json")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(load_unpins(self.env), ({}, True))
        self.assertIn("warning:", err.getvalue())
        self.assertNotIn("error:", err.getvalue())

    def test_non_object_file_is_dropped_with_a_warning(self):
        self.write_entries(["nixpkgs"])
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(load_unpins(self.env), ({}, True))
        self.assertIn("warning:", err.getvalue())

    def test_entry_without_last_modified_is_dropped(self):
        self.write_entries(
            {
                "nixpkgs": {"rev": NIXPKGS_REV},
                "home-manager": {"rev": HM_REV, "lastModified": 1},
            }
        )
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            entries, dirty = load_unpins(self.env)
        self.assertEqual(entries, {"home-manager": {"rev": HM_REV, "lastModified": 1}})
        self.assertTrue(dirty)
        self.assertIn("'nixpkgs'", err.getvalue())

    # The other malformed shape a hand edit or an older writer can produce.
    def test_bare_string_entry_is_dropped(self):
        self.write_entries({"nixpkgs": NIXPKGS_REV})
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(load_unpins(self.env), ({}, True))
        self.assertIn("'nixpkgs'", err.getvalue())

    def test_empty_rev_is_dropped(self):
        self.write_entries({"nixpkgs": {"rev": "", "lastModified": 1}})
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(load_unpins(self.env), ({}, True))
        self.assertIn("'nixpkgs'", err.getvalue())


class ToleranceTest(_Env):
    def test_corrupt_file_is_deleted_without_an_info_eval(self):
        self.path.write_text("{not json")
        err = io.StringIO()
        with (
            patch("build.update.cache_unpin_info") as info,
            contextlib.redirect_stderr(err),
        ):
            prepare_unpins(self.env, Options(), [])
        info.assert_not_called()
        self.assertFalse(self.path.exists())
        self.assertIn("warning:", err.getvalue())

    def test_malformed_entry_is_rewritten_before_genflake(self):
        kept = {"rev": "b" * 40, "lastModified": 4500}
        self.write_entries({"apps/foo": kept, "nixpkgs": {"rev": 5}})
        err = self.prepare()
        self.assertEqual(self.entries(), {"apps/foo": kept})
        self.assertIn("'nixpkgs'", err)


class RollbackNoteTest(unittest.TestCase):
    # Mirrors main.py's `persist`: a note only where the file is really reverted.
    def test_note_matrix(self):
        self.assertEqual(_rollback_note(Options()), "")
        self.assertEqual(_rollback_note(Options(dry=True)), " (rolled back: --dry)")
        self.assertEqual(
            _rollback_note(Options(genflake_only=True)),
            " (rolled back: --genflake-only)",
        )
        self.assertEqual(_rollback_note(Options(genflake_only=True, keep_flake=True)), "")
        self.assertEqual(
            _rollback_note(Options(genflake_only=True, lock_only=True)), ""
        )


class DateLookupTest(_Env):
    # A query in the url must stay last: `<stem>/<rev>?query`, not `<url>/<rev>`.
    def test_rev_goes_before_the_query(self):
        pin = CachePin(
            "github:icedos/foo?dir=sub", "github:icedos/foo?dir=sub", FOO_REV, None
        )
        seen: list[str] = []

        def fake_capture(cmd: list[str], **_kwargs: object) -> str:
            seen.append(cmd[-1])
            return json.dumps({"locked": {"rev": FOO_REV, "lastModified": 4000}})

        with patch("build.update.capture", side_effect=fake_capture):
            self.assertEqual(_cache_time("apps/foo", pin, {}), 4000)
        self.assertEqual(seen, [f"github:icedos/foo/{FOO_REV}?dir=sub"])

    def test_soft_failure_prints_no_error(self):
        pin = CachePin("github:icedos/foo", "github:icedos/foo/main", FOO_REV, None)
        err = io.StringIO()
        with (
            patch("build.update.capture", side_effect=SystemExit(1)),
            contextlib.redirect_stderr(err),
        ):
            self.assertIsNone(_cache_time("apps/foo", pin, {}))
        self.assertIn("warning:", err.getvalue())
        self.assertNotIn("error:", err.getvalue())

    def test_hard_failure_keeps_the_error(self):
        err = io.StringIO()
        with (
            patch("build.update.capture", side_effect=SystemExit(1)),
            contextlib.redirect_stderr(err),
            self.assertRaises(SystemExit),
        ):
            _ = _flake_metadata("github:icedos/foo/main")
        self.assertIn("error:", err.getvalue())


class RootlessTest(_Env):
    def test_no_config_root_is_a_no_op(self):
        entry = {"rev": NIXPKGS_REV, "lastModified": 1}
        self.write_entries({"nixpkgs": entry})
        env = BuildEnv(
            root=self.env.root,
            config_root=None,
            state_dir=self.state_dir,
            inputs_prefix="icedos",
        )
        with (
            patch("build.update.cache_unpin_info") as info,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            prepare_unpins(env, Options(unpin=True), [])
        info.assert_not_called()
        self.assertEqual(self.entries(), {"nixpkgs": entry})


class EvalTest(_Env):
    def test_info_eval_uses_the_contract_attr(self):
        payload = json.dumps(
            {
                "nixpkgs": {
                    "url": "github:nixos/nixpkgs",
                    "latestUrl": "github:nixos/nixpkgs/nixos-unstable",
                    "cacheRev": "a" * 40,
                    "cacheLastModified": 5,
                }
            }
        )
        with patch("build.genflake.capture", return_value=payload) as mock_capture:
            pins = cache_unpin_info(self.env, ["--show-trace"])
        self.assertEqual(
            pins,
            {
                "nixpkgs": CachePin(
                    "github:nixos/nixpkgs",
                    "github:nixos/nixpkgs/nixos-unstable",
                    "a" * 40,
                    5,
                )
            },
        )
        cmd = mock_capture.call_args.args[0]
        self.assertEqual(cmd[:4], ["nix", "eval", "--json", "--show-trace"])
        self.assertEqual(cmd[-1], "cacheUnpinInfo")
        self.assertEqual(mock_capture.call_args.kwargs["env"], {"ICEDOS_STAGE": "genflake"})

    def test_info_accepts_a_null_date(self):
        payload = json.dumps(
            {
                "apps/foo": {
                    "url": "github:icedos/foo",
                    "latestUrl": "github:icedos/foo/main",
                    "cacheRev": "e" * 40,
                    "cacheLastModified": None,
                }
            }
        )
        with patch("build.genflake.capture", return_value=payload):
            pins = cache_unpin_info(self.env, [])
        self.assertEqual(pins["apps/foo"].last_modified, None)

    def test_info_rejects_a_missing_rev(self):
        payload = '{"nixpkgs": {"url": "u", "latestUrl": "l"}}'
        with (
            patch("build.genflake.capture", return_value=payload),
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            _ = cache_unpin_info(self.env, [])

    def test_info_requires_the_latest_url(self):
        payload = json.dumps(
            {"nixpkgs": {"url": "github:nixos/nixpkgs", "cacheRev": "a" * 40,
                         "cacheLastModified": 5}}
        )
        with (
            patch("build.genflake.capture", return_value=payload),
            contextlib.redirect_stderr(io.StringIO()) as err,
            self.assertRaises(SystemExit),
        ):
            _ = cache_unpin_info(self.env, [])
        self.assertIn("cacheUnpinInfo is malformed", err.getvalue())


class PruneTest(_Env):
    def test_expired_by_rev(self):
        self.write_entries({"nixpkgs": {"rev": NIXPKGS_REV, "lastModified": 9999}})
        err = self.prepare()
        self.assertFalse(self.path.exists())
        self.assertIn("info: cache caught up with 'nixpkgs'", err)

    def test_expired_by_time(self):
        self.write_entries({"nixpkgs": {"rev": UNKNOWN_REV, "lastModified": 1000}})
        err = self.prepare()
        self.assertFalse(self.path.exists())
        self.assertIn("info: cache caught up with 'nixpkgs'", err)

    def test_expired_by_time_from_the_cache_rev_lookup(self):
        self.write_entries({"apps/foo": {"rev": UNKNOWN_REV, "lastModified": 1000}})
        err = self.prepare()
        self.assertFalse(self.path.exists())
        self.assertIn("cache caught up with 'apps/foo'", err)

    def test_metadata_failure_keeps_the_entry(self):
        entry = {"rev": UNKNOWN_REV, "lastModified": 1000}
        self.write_entries({"apps/foo": entry})
        err = self.prepare(failing=frozenset({f"github:icedos/foo/{FOO_REV}"}))
        self.assertEqual(self.entries(), {"apps/foo": entry})
        self.assertIn("cannot read the cache date for 'apps/foo'; keeping its unpin", err)

    def test_not_cache_pinned_any_more_drops_the_entry(self):
        self.write_entries({"apps/foo": {"rev": UNKNOWN_REV, "lastModified": 9999}})
        err = self.prepare(pins={"nixpkgs": PINS["nixpkgs"]})
        self.assertFalse(self.path.exists())
        self.assertIn("'apps/foo' is no longer cache-pinned", err)

    def test_entry_newer_than_the_cache_survives(self):
        entry = {"rev": UNKNOWN_REV, "lastModified": 9999}
        self.write_entries({"nixpkgs": entry})
        err = self.prepare()
        self.assertEqual(self.entries(), {"nixpkgs": entry})
        self.assertEqual(err, "")

    def test_no_file_and_no_flag_skips_the_eval(self):
        with patch(
            "build.update.cache_unpin_info", side_effect=AssertionError("no eval")
        ):
            prepare_unpins(self.env, Options(), [])

    def test_existing_file_evals_the_info_once(self):
        self.write_entries({"nixpkgs": {"rev": UNKNOWN_REV, "lastModified": 9999}})
        with patch(
            "build.update.cache_unpin_info", return_value=dict(PINS)
        ) as mock_info:
            prepare_unpins(self.env, Options(), [])
        mock_info.assert_called_once()


class ResolveTest(_Env):
    def test_unpin_writes_every_latest_rev(self):
        err = self.prepare(Options(unpin=True))
        self.assertEqual(
            self.entries(),
            {
                "apps/foo": {"rev": "f" * 40, "lastModified": 7000},
                "home-manager": {"rev": "b" * 40, "lastModified": 6000},
                "nixpkgs": {"rev": "a" * 40, "lastModified": 5000},
            },
        )
        self.assertIn("info: unpinned nixpkgs at aaaaaaa", err)
        self.assertFalse((self.state_dir / f"{CACHE_UNPIN_FILE}.icedos-tmp").exists())

    def test_select_writes_only_the_named_inputs(self):
        err = self.prepare(Options(unpin_names=["nixpkgs"]))
        self.assertEqual(
            self.entries(), {"nixpkgs": {"rev": "a" * 40, "lastModified": 5000}}
        )
        self.assertNotIn("home-manager", err)

    def test_merge_keeps_an_entry_it_did_not_resolve(self):
        fresh = {"rev": UNKNOWN_REV, "lastModified": 9999}
        self.write_entries({"home-manager": fresh})
        _err = self.prepare(Options(unpin_names=["nixpkgs"]))
        entries = self.entries()
        self.assertEqual(entries["home-manager"], fresh)
        self.assertEqual(entries["nixpkgs"]["rev"], "a" * 40)

    def test_re_resolve_reports_the_old_rev(self):
        self.write_entries({"nixpkgs": {"rev": UNKNOWN_REV, "lastModified": 9999}})
        err = self.prepare(Options(unpin_names=["nixpkgs"]))
        self.assertIn("info: unpinned nixpkgs at aaaaaaa (was zzzzzzz)", err)

    def test_already_at_the_cache_pin_by_rev(self):
        pins = {
            "nixpkgs": CachePin(
                "github:nixos/nixpkgs", "github:nixos/nixpkgs/nixos-unstable", "a" * 40, 2000
            )
        }
        err = self.prepare(Options(unpin_names=["nixpkgs"]), pins=pins)
        self.assertFalse(self.path.exists())
        self.assertIn("info: nixpkgs is already at the cache pin", err)

    def test_already_at_the_cache_pin_by_time(self):
        latest = {"github:nixos/nixpkgs/nixos-unstable": ("a" * 40, 1500)}
        err = self.prepare(Options(unpin_names=["nixpkgs"]), latest=latest)
        self.assertFalse(self.path.exists())
        self.assertIn("info: nixpkgs is already at the cache pin", err)

    def test_unknown_name_errors_listing_valid_names(self):
        err = io.StringIO()
        with (
            patch("build.update.cache_unpin_info", return_value=dict(PINS)),
            patch("build.update.capture", return_value="{}"),
            contextlib.redirect_stderr(err),
            self.assertRaises(SystemExit) as ctx,
        ):
            prepare_unpins(self.env, Options(unpin_names=["nope"]), [])
        self.assertEqual(ctx.exception.code, 1)
        self.assertIn("error: 'nope' is not a cache-pinned input", err.getvalue())
        self.assertIn("valid names: apps/foo, home-manager, nixpkgs", err.getvalue())
        self.assertFalse(self.path.exists())

    def test_update_except_skips_with_a_warning(self):
        err = self.prepare(
            Options(unpin_names=["nixpkgs", "home-manager"], update_except=["nixpkgs"])
        )
        self.assertEqual(sorted(self.entries()), ["home-manager"])
        self.assertIn("warning: --update-except keeps 'nixpkgs' at its locked rev", err)

    def test_all_selected_excluded_writes_nothing(self):
        err = self.prepare(
            Options(unpin_names=["nixpkgs"], update_except=["nixpkgs"])
        )
        self.assertFalse(self.path.exists())
        self.assertIn("every selected input is excluded", err)

    def test_no_cache_pinned_inputs_warns(self):
        err = self.prepare(Options(unpin=True), pins={})
        self.assertFalse(self.path.exists())
        self.assertIn("warning: no cache-pinned inputs to unpin", err)

    def test_resolution_uses_the_latest_url(self):
        calls: list[str] = []

        def fake_capture(cmd: list[str], **_kwargs: object) -> str:
            calls.append(cmd[-1])
            rev, mtime = LATEST[cmd[-1]]
            return json.dumps({"locked": {"rev": rev, "lastModified": mtime}})

        with (
            patch("build.update.cache_unpin_info", return_value=dict(PINS)),
            patch("build.update.capture", side_effect=fake_capture),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            prepare_unpins(self.env, Options(unpin_names=["nixpkgs"]), [])
        # The channel url, not the rev-less base url.
        self.assertEqual(calls, ["github:nixos/nixpkgs/nixos-unstable"])
        self.assertEqual(self.entries()["nixpkgs"]["rev"], "a" * 40)

    def test_unknown_cache_date_still_unpins(self):
        pins = {
            "nixpkgs": CachePin(
                "github:nixos/nixpkgs",
                "github:nixos/nixpkgs/nixos-unstable",
                NIXPKGS_REV,
                None,
            )
        }
        err = self.prepare(
            Options(unpin_names=["nixpkgs"]),
            pins=pins,
            failing=frozenset({f"github:nixos/nixpkgs/{NIXPKGS_REV}"}),
        )
        self.assertEqual(self.entries()["nixpkgs"]["rev"], "a" * 40)
        self.assertIn("cannot read the cache date for 'nixpkgs'", err)


class CachePinVsUnpinTest(_Env):
    def test_state_inputs_bumps_the_cache_pin_but_the_unpin_keeps_its_rev(self):
        err = io.StringIO()
        opts = Options(state_inputs=["nixpkgs"])
        with (
            patch("build.update.run") as mock_run,
            contextlib.redirect_stderr(err),
        ):
            kept = update_cache_pin(
                self.env, opts, ["nixpkgs", "home-manager"], {"nixpkgs"}
            )
        mock_run.assert_called_once_with(
            ["nix", "flake", "update", "icedos/cache-server", "--refresh"],
            cwd=self.config_root,
            check=True,
        )
        self.assertEqual(kept, ["home-manager"])
        self.assertIn("nixpkgs is unpinned; the cache pin moves", err.getvalue())

    def test_state_inputs_bumps_the_other_pin_without_freezing_the_unpin(self):
        opts = Options(state_inputs=["home-manager"])
        with patch("build.update.run") as mock_run:
            kept = update_cache_pin(
                self.env, opts, ["nixpkgs", "home-manager"], {"nixpkgs"}
            )
        mock_run.assert_called_once_with(
            ["nix", "flake", "update", "icedos/cache-server", "--refresh"],
            cwd=self.config_root,
            check=True,
        )
        self.assertEqual(kept, [])


if __name__ == "__main__":
    unittest.main()
