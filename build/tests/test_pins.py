from __future__ import annotations

import io
import json
import tempfile
import unittest
from collections.abc import Generator
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path
from types import ModuleType
from typing import cast
from unittest import mock

import subprocess

from build import pins as pins_mod
from build.context import BuildEnv
from build.pins import _Git
from build.options import Options
from build.pins import (
    UNPINNED_FILE,
    AncestryFn,
    _git_url,
    _ident_to_url,
    _lock_leaf,
    _normalise_entry,
    _read_unpinned,
    decide_pin,
    expire_unpinned,
    unpin_inputs,
)
from build.util import JSON


def _no_ask(_message: str) -> bool:
    return False


def _yes_ask(_message: str) -> bool:
    return True


def _ancestry(map: dict[tuple[str, str], bool]) -> AncestryFn:
    return lambda a, b: map.get((a, b))


class DecidePinTest(unittest.TestCase):
    def test_case_1_cache_behind_master_asks_to_repin(self):
        action, rev = decide_pin(
            "x", "aaa", "", "bbb", _ancestry({("aaa", "bbb"): True}), _yes_ask
        )
        self.assertEqual((action, rev), ("save", "bbb"))

    def test_case_1_declined_keeps_the_cache_pin(self):
        action, rev = decide_pin(
            "x", "aaa", "", "bbb", _ancestry({("aaa", "bbb"): True}), _no_ask
        )
        self.assertEqual((action, rev), ("keep", ""))

    def test_case_2_cache_equals_master_is_a_noop(self):
        action, rev = decide_pin("x", "aaa", "", "aaa", _ancestry({}), _yes_ask)
        self.assertEqual((action, rev), ("noop", ""))

    def test_cache_already_ahead_of_master_does_not_repin(self):
        action, rev = decide_pin(
            "x", "bbb", "", "aaa", _ancestry({("aaa", "bbb"): True}), _yes_ask
        )
        self.assertEqual((action, rev), ("noop", ""))

    def test_case_3_master_moved_past_the_custom_pin_asks(self):
        # Cache (ccc) is behind the custom pin (bbb); master (ddd) moved past it.
        ancestry = _ancestry({("bbb", "ddd"): True})
        action, rev = decide_pin("x", "ccc", "bbb", "ddd", ancestry, _yes_ask)
        self.assertEqual((action, rev), ("save", "ddd"))
        action, rev = decide_pin("x", "ccc", "bbb", "ddd", ancestry, _no_ask)
        self.assertEqual((action, rev), ("keep", ""))

    def test_custom_pin_already_at_master_keeps(self):
        action, rev = decide_pin("x", "ccc", "bbb", "bbb", _ancestry({}), _yes_ask)
        self.assertEqual((action, rev), ("keep", ""))

    def test_case_4_cache_reached_the_custom_pin_clears(self):
        self.assertEqual(decide_pin("x", "bbb", "bbb", "bbb", _ancestry({}), _yes_ask)[0], "clear")
        self.assertEqual(
            decide_pin("x", "ddd", "bbb", "ddd", _ancestry({("bbb", "ddd"): True}), _yes_ask)[0],
            "clear",
        )

    def test_untracked_cache_clears_the_remembered_pin(self):
        action, rev = decide_pin("x", "", "bbb", "", _ancestry({}), _yes_ask)
        self.assertEqual((action, rev), ("clear", ""))

    def test_no_saved_pin_and_untracked_cache_skips(self):
        action, rev = decide_pin("x", "", "", "aaa", _ancestry({}), _yes_ask)
        self.assertEqual((action, rev), ("skip", ""))

    def test_unknown_master_keeps_the_current_pin(self):
        self.assertEqual(decide_pin("x", "aaa", "", "", _ancestry({}), _yes_ask)[0], "noop")
        self.assertEqual(decide_pin("x", "ccc", "bbb", "", _ancestry({}), _yes_ask)[0], "keep")

    def test_master_moved_backward_keeps_the_custom_pin(self):
        action, rev = decide_pin(
            "x", "ccc", "bbb", "aaa", _ancestry({("bbb", "aaa"): False}), _yes_ask
        )
        self.assertEqual((action, rev), ("keep", ""))


class EntryHelpersTest(unittest.TestCase):
    def test_normalise_entry_string_and_attrs(self):
        self.assertEqual(_normalise_entry("abc"), {"rev": "abc", "repo": "", "checked": ""})
        self.assertEqual(
            _normalise_entry({"rev": "abc", "repo": "github:o/r"}),
            {"rev": "abc", "repo": "github:o/r", "checked": ""},
        )
        self.assertEqual(_normalise_entry(None), {"rev": "", "repo": "", "checked": ""})

    def test_lock_leaf_exact_and_suffixed_keys(self):
        lock: JSON = {
            "nodes": {
                "root": {"inputs": {}},
                "github:o/r": {"original": {"type": "github", "owner": "o", "repo": "r"}},
                "icedos-sub-r": {"original": {"type": "github", "owner": "o2", "repo": "r2"}},
            }
        }
        first = cast("dict[str, JSON]", _lock_leaf(lock, "github:o/r")["original"])
        second = cast("dict[str, JSON]", _lock_leaf(lock, "r")["original"])
        self.assertEqual(first["owner"], "o")
        self.assertEqual(second["repo"], "r2")

    def test_lock_leaf_follows_subflake_root_to_the_leaf(self):
        # The cache-server publishes keys shaped like the sub-flake root
        # (`icedos-<repo>-<module>`); the leaf hangs off its inputs map.
        lock: JSON = {
            "nodes": {
                "icedos-github_icedos_kde-plasmazones": {
                    "inputs": {"plasmazones": "github:polito/plasmazones"},
                    "original": {"type": "path", "path": "/nix/store/x-subflake"},
                },
                "github:polito/plasmazones": {
                    "original": {"type": "github", "owner": "polito", "repo": "PlasmaZones"}
                },
            }
        }
        leaf = _lock_leaf(lock, "icedos-github_icedos_kde-plasmazones")
        original = cast("dict[str, JSON]", leaf["original"])
        self.assertEqual(original["owner"], "polito")

    def test_lock_leaf_refuses_ambiguous_suffixes(self):
        lock: JSON = {
            "nodes": {
                "icedos-a-r": {"original": {"type": "github", "owner": "o", "repo": "r"}},
                "icedos-b-r": {"original": {"type": "github", "owner": "o2", "repo": "r2"}},
            }
        }
        self.assertEqual(_lock_leaf(lock, "r"), {})

    def test_git_url_from_entry_and_lock_fallback(self):
        self.assertEqual(
            _git_url({"rev": "a", "repo": "github:o/r"}, {}, "x"),
            "https://github.com/o/r",
        )
        lock: JSON = {"nodes": {"x": {"original": {"type": "github", "owner": "o", "repo": "r"}}}}
        self.assertEqual(_git_url({"rev": "a", "repo": ""}, lock, "x"), "https://github.com/o/r")

    def test_ident_to_url_scheme_allowlist_and_host_override(self):
        self.assertEqual(_ident_to_url("ext::sh -c evil"), "")
        self.assertEqual(_ident_to_url("file:///etc/passwd"), "")
        self.assertEqual(
            _git_url({"rev": "a", "repo": "ext::sh -c evil://x"}, {}, "x"), ""
        )
        lock: JSON = {
            "nodes": {
                "x": {
                    "original": {
                        "type": "gitlab",
                        "owner": "o",
                        "repo": "r",
                        "host": "ghe.example",
                    }
                }
            }
        }
        self.assertEqual(_git_url({"rev": "a", "repo": ""}, lock, "x"), "https://ghe.example/o/r")

    def test_git_url_refuses_tracked_repo_that_disagrees_with_the_lock(self):
        lock: JSON = {"nodes": {"x": {"original": {"type": "github", "owner": "o", "repo": "r"}}}}
        self.assertEqual(_git_url({"rev": "a", "repo": "github:o2/r2"}, lock, "x"), "")
        # The lock leaf is authoritative even when the entry carries a repo.
        self.assertEqual(_git_url({"rev": "a", "repo": "github:o/r"}, lock, "x"), "https://github.com/o/r")

    def test_git_url_sourcehut_keeps_owner_tilde_and_gitlab_subgroups(self):
        self.assertEqual(
            _git_url({"rev": "a", "repo": "sourcehut:~ice/r"}, {}, "x"),
            "https://git.sr.ht/~ice/r",
        )
        self.assertEqual(
            _git_url({"rev": "a", "repo": "gitlab:g%2Fsub/r"}, {}, "x"),
            "https://gitlab.com/g/sub/r",
        )


class PrunePassTest(unittest.TestCase):
    def test_drops_pins_the_cache_no_longer_tracks(self):
        saved: dict[str, JSON] = {
            "x": {"rev": "bbb", "repo": ""},
            "y": {"rev": "ccc", "repo": ""},
        }
        changed = pins_mod._prune_pass(saved, {"y": "ddd"}, {}, _FakeGit({}, {}), set())
        self.assertTrue(changed)
        self.assertEqual(saved, {"y": {"rev": "ccc", "repo": ""}})


class GitGuardTest(unittest.TestCase):
    def test_is_ancestor_refuses_non_sha_revs_without_spawning_git(self):
        git = _Git()
        with mock.patch.object(
            subprocess, "run", side_effect=AssertionError("git called")
        ):
            self.assertIsNone(git.is_ancestor("https://github.com/o/r", "--evil", "bbb"))
            self.assertIsNone(git.is_ancestor("https://github.com/o/r", "aaa", "not a sha"))


class UnpinnedFileTest(unittest.TestCase):
    def test_read_unpinned_roundtrip_and_tolerates_garbage(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / UNPINNED_FILE
            self.assertEqual(_read_unpinned(path), {})
            _ = path.write_text(json.dumps({"x": {"rev": "abc", "repo": "github:o/r"}}))
            self.assertEqual(_read_unpinned(path), {"x": {"rev": "abc", "repo": "github:o/r"}})
            _ = path.write_text("not json")
            self.assertEqual(_read_unpinned(path), {})
            self.assertEqual(path.read_text(), "{}")  # garbage self-heals
            _ = path.write_text("null")  # valid JSON, but not an object
            self.assertEqual(_read_unpinned(path), {})
            self.assertEqual(path.read_text(), "{}")


class _FakeGit:
    def __init__(
        self,
        heads: dict[str, str],
        ancestry: dict[tuple[str, str], bool | None],
        ref_heads: dict[tuple[str, str], str] | None = None,
    ) -> None:
        self._heads: dict[str, str] = heads
        self._ref_heads: dict[tuple[str, str], str] = ref_heads or {}
        self._ancestry: dict[tuple[str, str], bool | None] = ancestry
        self.head_calls: list[str] = []
        self.ref_calls: list[tuple[str, str]] = []
        self.probes: int = 0
        self._counted: set[tuple[str, str, str]] = set()

    def head(self, url: str) -> str:
        self.head_calls.append(url)
        return self._heads.get(url, "")

    def ref_head(self, url: str, ref: str) -> str:
        self.ref_calls.append((url, ref))
        return self._ref_heads.get((url, ref), "")

    def is_ancestor(self, url: str, a: str, b: str) -> bool | None:
        # Count unique triples only, mirroring the real _Git's per-key memoization.
        if (url, a, b) not in self._counted:
            self._counted.add((url, a, b))
            self.probes += 1
        return self._ancestry.get((a, b))


@contextmanager
def _patched(
    pins: ModuleType,
    pin_revs: dict[str, JSON],
    git: object,
    refs: dict[str, str] | None = None,
) -> Generator[None]:
    def fake_revs(_env: BuildEnv, _trace: list[str]) -> tuple[dict[str, JSON], dict[str, str]]:
        return pin_revs, refs or {}

    with (
        mock.patch.object(pins, "_pin_revs", fake_revs),
        mock.patch.object(pins, "_Git", lambda: git),
        # io.StringIO().isatty() is False, forcing the non-interactive path.
        mock.patch("sys.stdin", io.StringIO()),
    ):
        yield


class OrchestrationTest(unittest.TestCase):
    # A state lock whose leaf node resolves "x" to github:o/x, so _git_url's
    # lock fallback produces a url for the fake git.
    LOCK: str = json.dumps(
        {"nodes": {"x": {"original": {"type": "github", "owner": "o", "repo": "x"}}}}
    )

    def _env(self, tmp: str) -> BuildEnv:
        return BuildEnv(
            root=Path("/x"),
            config_root=None,
            state_dir=Path(tmp),
            inputs_prefix="icedos",
        )

    def test_expired_pin_is_cleared_then_freshly_evaluated(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            _ = path.write_text(json.dumps({"x": {"rev": "bbb", "repo": ""}}))
            # Cache moved past the remembered pin; master equals the cache rev.
            git = _FakeGit({"https://github.com/o/x": "ddd"}, {("bbb", "ddd"): True})
            opts = Options()
            opts.unpin_inputs = ["x"]
            with _patched(pins_mod, {"x": "ddd"}, git):
                with redirect_stdout(io.StringIO()) as out:
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertEqual(json.loads(path.read_text()), {})
            self.assertIn("x custom pin dropped; back on the cache-server's rev", out.getvalue())
            self.assertIn("x is already at master; nothing to do", out.getvalue())

    def test_stale_pin_with_master_behind_is_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            _ = path.write_text(json.dumps({"x": {"rev": "bbb", "repo": ""}}))
            # Cache behind the pin, master behind it too.
            git = _FakeGit({"https://github.com/o/x": "aaa"}, {("bbb", "aaa"): False})
            opts = Options()
            opts.unpin_inputs = ["x"]
            with _patched(pins_mod, {"x": "ccc"}, git):
                with redirect_stdout(io.StringIO()) as out:
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertEqual(
                json.loads(path.read_text()), {"x": {"rev": "bbb", "repo": ""}}
            )
            self.assertIn("keeps its custom pin", out.getvalue())

    def test_unresolvable_master_warns_and_skips(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            # A forge leaf must pass the scheme gate so the failure under test
            # (no upstream rev) is actually reached.
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            _ = path.write_text(json.dumps({"x": {"rev": "bbb", "repo": "github:o/x"}}))
            git = _FakeGit({}, {})  # no lock, no heads -> no master rev
            opts = Options()
            opts.unpin_inputs = ["x"]
            with _patched(pins_mod, {"x": "ccc"}, git):
                err = io.StringIO()
                with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", err):
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertEqual(
                json.loads(path.read_text()), {"x": {"rev": "bbb", "repo": "github:o/x"}}
            )
            self.assertIn("no resolvable git url or upstream rev", err.getvalue())

    def test_expire_unpinned_prunes_without_prompting(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            _ = path.write_text(json.dumps({"x": {"rev": "bbb", "repo": ""}}))
            git = _FakeGit({}, {("bbb", "ddd"): True})
            with _patched(pins_mod, {"x": "ddd"}, git):
                expire_unpinned(self._env(tmp), [])
            self.assertEqual(json.loads(path.read_text()), {})

    def test_unpin_all_covers_every_lock_resolvable_tracked_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            git = _FakeGit(
                {"https://github.com/o/x": "ddd", "https://github.com/o/y": "eee"},
                {("aaa", "ddd"): True},
            )
            opts = Options()
            opts.unpin_all = True
            # x is behind master and accepts the re-pin; y carries its own
            # repo but no lock node, so it is still skipped; z is bare string.
            pin_revs: dict[str, JSON] = {
                "x": "aaa",
                "y": {"rev": "ccc", "repo": "github:o/y"},
                "z": "bbb",
            }

            def _answer(_msg: str) -> str:
                return "y"

            # MagicMock().isatty() is truthy, forcing the interactive path.
            with (
                _patched(pins_mod, pin_revs, git),
                mock.patch("sys.stdin", mock.MagicMock()),
                mock.patch("builtins.input", _answer),
            ):
                with redirect_stdout(io.StringIO()) as out:
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertEqual(
                json.loads(path.read_text()),
                {"x": {"rev": "ddd", "repo": "github:o/x"}},
            )
            self.assertIn("x re-pinned to master", out.getvalue())

    def test_expire_unpinned_memoizes_the_ancestry_probe(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            _ = path.write_text(json.dumps({"x": {"rev": "bbb", "repo": ""}}))
            # Cache behind the pin, ancestry definitively False: stamp the
            # probed cache rev so the second run skips the git probe entirely.
            # One fresh _FakeGit per run (real _Git-per-run behavior), so the
            # second run's zero probes can only come from the checked stamp.
            pin_revs: dict[str, JSON] = {"x": "ccc"}

            def fake_pin_revs(
                _env: BuildEnv, _trace: list[str]
            ) -> tuple[dict[str, JSON], dict[str, str]]:
                return pin_revs, {}

            fakes = [
                _FakeGit({"https://github.com/o/x": ""}, {("bbb", "ccc"): False}),
                _FakeGit({"https://github.com/o/x": ""}, {("bbb", "ccc"): False}),
            ]
            git_iter = iter(fakes)

            def fake_git() -> _FakeGit:
                return next(git_iter)

            with (
                mock.patch.object(pins_mod, "_pin_revs", fake_pin_revs),
                mock.patch.object(pins_mod, "_Git", fake_git),
                mock.patch("sys.stdin", io.StringIO()),
            ):
                env = self._env(tmp)
                expire_unpinned(env, [])
                expire_unpinned(env, [])
            self.assertEqual([f.probes for f in fakes], [1, 0])
            self.assertEqual(
                json.loads(path.read_text()),
                {"x": {"rev": "bbb", "repo": "", "checked": "ccc"}},
            )

    def test_expire_unpinned_reprobes_when_ancestry_is_inconclusive(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            _ = path.write_text(json.dumps({"x": {"rev": "bbb", "repo": ""}}))
            # A fresh _Git per run (real behavior); ancestry unknown, so every
            # run must re-probe instead of trusting a stamp.
            fakes = [_FakeGit({"https://github.com/o/x": ""}, {}) for _ in range(2)]
            pin_revs: dict[str, JSON] = {"x": "ccc"}

            def fake_pin_revs(
                _env: BuildEnv, _trace: list[str]
            ) -> tuple[dict[str, JSON], dict[str, str]]:
                return pin_revs, {}

            git_iter = iter(fakes)

            def fake_git() -> _FakeGit:
                return next(git_iter)

            with (
                mock.patch.object(pins_mod, "_pin_revs", fake_pin_revs),
                mock.patch.object(pins_mod, "_Git", fake_git),
                mock.patch("sys.stdin", io.StringIO()),
            ):
                env = self._env(tmp)
                expire_unpinned(env, [])
                expire_unpinned(env, [])
            self.assertEqual(sum(f.probes for f in fakes), 2)
            self.assertEqual(json.loads(path.read_text()), {"x": {"rev": "bbb", "repo": ""}})

    def test_prompt_survives_eof(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            git = _FakeGit({"https://github.com/o/x": "bbb"}, {("aaa", "bbb"): True})
            opts = Options()
            opts.unpin_inputs = ["x"]

            def _eof(_msg: str) -> str:
                raise EOFError

            with _patched(pins_mod, {"x": "aaa"}, git), mock.patch(
                "sys.stdin", mock.MagicMock()
            ), mock.patch("builtins.input", _eof):
                with redirect_stdout(io.StringIO()) as out:
                    unpin_inputs(self._env(tmp), opts, [])
            # A declined prompt writes nothing: the state file is not created.
            self.assertFalse(path.exists())
            self.assertIn("keeps the cache-server's pin", out.getvalue())

    def test_expired_pin_clears_before_the_master_lookup(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            _ = path.write_text(json.dumps({"x": {"rev": "ddd", "repo": ""}}))
            # Case 4 (cache_rev == saved_rev) is decidable without the network:
            # no ancestry probe, and the clear happens even though ls-remote
            # would fail (no heads).
            git = _FakeGit({}, {})
            opts = Options()
            opts.unpin_inputs = ["x"]
            with _patched(pins_mod, {"x": "ddd"}, git):
                with redirect_stdout(io.StringIO()) as out:
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertEqual(json.loads(path.read_text()), {})
            self.assertEqual(git.probes, 0)
            self.assertIn("x custom pin dropped", out.getvalue())

    def test_unpin_skips_non_forge_inputs_before_prompting(self):
        # A git-type leaf (no forge repo): skipped before any upstream lookup,
        # so the user is never asked for a pin that cannot be applied.
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(json.dumps({
                "nodes": {
                    "x": {"original": {"type": "git", "url": "https://example.com/x.git"}}
                }
            }))
            path = state / UNPINNED_FILE
            git = _FakeGit({"https://example.com/x.git": "ddd"}, {})
            opts = Options()
            opts.unpin_inputs = ["x"]

            def _no_ask(_msg: str) -> str:
                raise AssertionError("must not prompt for non-forge inputs")

            with _patched(pins_mod, {"x": "aaa"}, git, refs={}), mock.patch(
                "sys.stdin", mock.MagicMock()
            ), mock.patch("builtins.input", _no_ask):
                with redirect_stderr(io.StringIO()) as err:
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertFalse(path.exists())
            self.assertIn("not a github/gitlab/sourcehut input", err.getvalue())
            self.assertEqual(git.head_calls, [])

    def test_root_input_names_exclude_subflake_roots(self):
        # A sub-flake ROOT is a root input but a legit tracked key (its leaf
        # hangs off its inputs map); only repo/channel-level names count here.
        lock: dict[str, JSON] = {
            "nodes": {
                "root": {
                    "inputs": {
                        "icedos-github_icedos_apps": "repo",
                        "icedos-github_icedos_apps-celluloid": "sub",
                    }
                },
                "repo": {"original": {"type": "github", "owner": "IceDOS", "repo": "apps"}},
                "sub": {
                    "original": {
                        "type": "path",
                        "path": "/nix/store/x-icedos-github_icedos_apps-celluloid-subflake",
                    }
                },
            }
        }
        self.assertEqual(
            pins_mod._root_input_names(lock),
            {"icedos-github_icedos_apps"},
        )

    def test_ref_head_prefers_branch_then_peeled_tag_commit(self):
        branch_sha, tag_obj, tag_commit = "a" * 40, "b" * 40, "c" * 40
        git = _Git()
        out = (
            f"{branch_sha}\trefs/heads/release\n"
            + f"{tag_obj}\trefs/tags/v1\n"
            + f"{tag_commit}\trefs/tags/v1^{{}}\n"
        )
        with mock.patch.object(subprocess, "run", return_value=mock.MagicMock(returncode=0, stdout=out)):
            self.assertEqual(git.ref_head("https://github.com/o/x", "release"), branch_sha)
            # An annotated tag resolves to the peeled commit, not the tag object.
            self.assertEqual(git.ref_head("https://github.com/o/x", "v1"), tag_commit)

    def test_unpin_targets_the_declared_ref_not_head(self):
        # A module declared `github:o/x/release`; the re-pin must offer that
        # branch's rev, never the remote's HEAD.
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            git = _FakeGit(
                {"https://github.com/o/x": "ddd"},
                {("aaa", "bbb"): True, ("bbb", "ccc"): False},
                {("https://github.com/o/x", "release"): "ccc"},
            )
            opts = Options()
            opts.unpin_inputs = ["x"]

            def _answer(_msg: str) -> str:
                return "y"

            with _patched(pins_mod, {"x": "aaa"}, git, refs={"x": "release"}), mock.patch(
                "sys.stdin", mock.MagicMock()
            ), mock.patch("builtins.input", _answer):
                with redirect_stdout(io.StringIO()) as out:
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertEqual(git.ref_calls, [("https://github.com/o/x", "release")])
            self.assertEqual(json.loads(path.read_text()), {"x": {"rev": "ccc", "repo": "github:o/x"}})
            self.assertIn("re-pinned to 'release'", out.getvalue())

    def test_unpin_skips_when_the_declared_ref_has_no_remote_rev(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(self.LOCK)
            path = state / UNPINNED_FILE
            git = _FakeGit({"https://github.com/o/x": "ddd"}, {}, {("https://github.com/o/x", "gone"): ""})
            opts = Options()
            opts.unpin_inputs = ["x"]
            with _patched(pins_mod, {"x": "aaa"}, git, refs={"x": "gone"}), mock.patch(
                "sys.stdin", mock.MagicMock()
            ):
                with redirect_stderr(io.StringIO()) as err:
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertFalse(path.exists())
            self.assertIn("upstream rev for refs 'gone'", err.getvalue())

    def test_unpin_all_skips_repo_level_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(json.dumps({
                "nodes": {
                    "root": {"inputs": {"icedos-github_icedos_kde": "icedos-github_icedos_kde"}},
                    "icedos-github_icedos_kde": {
                        "original": {"type": "github", "owner": "IceDOS", "repo": "kde"}
                    },
                    "x": {"original": {"type": "github", "owner": "o", "repo": "x"}},
                }
            }))
            path = state / UNPINNED_FILE
            git = _FakeGit({"https://github.com/o/x": "bbb"}, {("aaa", "bbb"): True})
            opts = Options()
            opts.unpin_all = True

            def _answer(_msg: str) -> str:
                return "y"

            with _patched(pins_mod, {"icedos-github_icedos_kde": "aaa", "x": "aaa"}, git), mock.patch(
                "sys.stdin", mock.MagicMock()
            ), mock.patch("builtins.input", _answer):
                with redirect_stdout(io.StringIO()) as out:
                    unpin_inputs(self._env(tmp), opts, [])
            # The repo-level tracked input is skipped; the leaf re-pins.
            self.assertEqual(
                json.loads(path.read_text()),
                {"x": {"rev": "bbb", "repo": "github:o/x"}},
            )
            self.assertIn("re-pinned to master", out.getvalue())

    def test_unpin_inputs_rejects_repo_level_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            _ = (state / "flake.lock").write_text(json.dumps({
                "nodes": {
                    "root": {"inputs": {"icedos-github_icedos_kde": "icedos-github_icedos_kde"}},
                    "icedos-github_icedos_kde": {
                        "original": {"type": "github", "owner": "IceDOS", "repo": "kde"}
                    },
                }
            }))
            opts = Options()
            opts.unpin_inputs = ["icedos-github_icedos_kde"]
            with _patched(pins_mod, {"icedos-github_icedos_kde": "aaa"}, _FakeGit({}, {})):
                err = io.StringIO()
                with redirect_stderr(err):
                    with self.assertRaises(SystemExit):
                        unpin_inputs(self._env(tmp), opts, [])
            self.assertIn("repo-level input", err.getvalue())

    def test_save_skips_non_forge_inputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            git_leaf = json.dumps(
                {"nodes": {"x": {"original": {"type": "git", "url": "https://github.com/o/x"}}}}
            )
            _ = (state / "flake.lock").write_text(git_leaf)
            path = state / UNPINNED_FILE
            git = _FakeGit({"https://github.com/o/x": "bbb"}, {("aaa", "bbb"): True})
            opts = Options()
            opts.unpin_inputs = ["x"]

            def _answer(_msg: str) -> str:
                return "y"

            with _patched(pins_mod, {"x": "aaa"}, git), mock.patch(
                "sys.stdin", mock.MagicMock()
            ), mock.patch("builtins.input", _answer):
                with redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()) as err:
                    unpin_inputs(self._env(tmp), opts, [])
            self.assertFalse(path.exists())
            self.assertIn("not a github/gitlab/sourcehut input", err.getvalue())

    def test_expire_unpinned_skips_the_eval_without_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(
                pins_mod, "_pin_revs"
            ) as pin_revs, mock.patch("sys.stdin", io.StringIO()):
                expire_unpinned(self._env(tmp), [])
            pin_revs.assert_not_called()


if __name__ == "__main__":
    _ = unittest.main()
