from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from typing import cast

from build import lockfile
from build.util import JSON

# A state lock with one sub-flake root, a nested local path input, a nested store
# path input, a plain github root input, and follows entries (lists, not keys).
LOCK: dict[str, JSON] = {
    "nodes": {
        "root": {
            "inputs": {
                "sub": "sub-node",
                "nixpkgs": "nixpkgs-node",
                "local": "local-node",
                "followed": ["nixpkgs"],
            }
        },
        "sub-node": {
            "inputs": {
                "nested": "nested-node",
                "vendored": "vendored-node",
                "followed": ["nixpkgs"],
            },
            "locked": {"type": "path", "path": "/nix/store/hash-sub-subflake"},
        },
        "nixpkgs-node": {
            "locked": {"type": "github", "owner": "o", "repo": "r", "rev": "deadbeef"}
        },
        "local-node": {"locked": {"type": "path", "path": "/home/u/checkout"}},
        "nested-node": {"locked": {"type": "path", "path": "/home/u/nested"}},
        "vendored-node": {"locked": {"type": "path", "path": "/nix/store/hash-thing"}},
    }
}


def _lock_with_sub_node_path(path: str) -> dict[str, JSON]:
    lock = cast("dict[str, JSON]", json.loads(json.dumps(LOCK)))
    node = cast("dict[str, JSON]", lock["nodes"])
    sub = cast("dict[str, JSON]", node["sub-node"])
    locked = cast("dict[str, JSON]", sub["locked"])
    locked["path"] = path
    return lock


class SubflakeTest(unittest.TestCase):
    def test_requires_store_prefix_and_name_suffix(self):
        self.assertEqual(lockfile.subflakes_from_lock(LOCK), ["sub"])

    def test_store_path_without_the_suffix_is_not_a_subflake(self):
        lock = _lock_with_sub_node_path("/nix/store/hash-sub")
        self.assertEqual(lockfile.subflakes_from_lock(lock), [])

    def test_local_path_is_not_a_subflake(self):
        lock = _lock_with_sub_node_path("/home/u/sub-subflake")
        self.assertEqual(lockfile.subflakes_from_lock(lock), [])


class NestedInputsTest(unittest.TestCase):
    def test_nested_path_inputs_excludes_store_paths_and_follows(self):
        self.assertEqual(lockfile.nested_path_inputs(LOCK, "sub"), ["nested"])

    def test_string_inputs_excludes_follows_lists(self):
        self.assertEqual(
            sorted(lockfile.string_inputs(LOCK, "sub")), ["nested", "vendored"]
        )

    def test_unknown_subflake_yields_nothing(self):
        self.assertEqual(lockfile.nested_path_inputs(LOCK, "nope"), [])
        self.assertEqual(lockfile.string_inputs(LOCK, "nope"), [])


class RootInputsTest(unittest.TestCase):
    def test_path_nodes_lists_every_path_typed_node(self):
        self.assertEqual(
            sorted(lockfile.path_nodes(LOCK)),
            ["local-node", "nested-node", "sub-node", "vendored-node"],
        )

    def test_path_inputs_lists_root_inputs_locked_to_a_path(self):
        self.assertEqual(sorted(lockfile.path_inputs(LOCK)), ["local", "sub"])

    def test_input_locked_path(self):
        self.assertEqual(lockfile.input_locked_path(LOCK, "local"), "/home/u/checkout")
        self.assertEqual(lockfile.input_locked_path(LOCK, "nixpkgs"), "")
        self.assertEqual(lockfile.input_locked_path(LOCK, "followed"), "")

    def test_input_is_string_rejects_follows_entries(self):
        self.assertTrue(lockfile.input_is_string(LOCK, "nixpkgs"))
        self.assertFalse(lockfile.input_is_string(LOCK, "followed"))
        self.assertFalse(lockfile.input_is_string(LOCK, "absent"))


class MalformedTest(unittest.TestCase):
    def test_every_helper_tolerates_an_empty_lock(self):
        empty_locks: list[dict[str, JSON]] = [
            {},
            {"nodes": {}},
            {"nodes": {"root": {}}},
        ]
        for lock in empty_locks:
            self.assertEqual(lockfile.path_nodes(lock), [])
            self.assertEqual(lockfile.path_inputs(lock), [])
            self.assertEqual(lockfile.subflakes_from_lock(lock), [])
            self.assertEqual(lockfile.nested_path_inputs(lock, "sub"), [])
            self.assertEqual(lockfile.string_inputs(lock, "sub"), [])
            self.assertEqual(lockfile.input_locked_path(lock, "sub"), "")
            self.assertFalse(lockfile.input_is_string(lock, "sub"))


class LoadLockTest(unittest.TestCase):
    def test_missing_file_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(lockfile.load_lock(Path(d) / "flake.lock"), {})

    def test_unparseable_file_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "flake.lock"
            _ = path.write_text("{not json")
            self.assertEqual(lockfile.load_lock(path), {})

    def test_non_object_top_level_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "flake.lock"
            _ = path.write_text("[1, 2]")
            self.assertEqual(lockfile.load_lock(path), {})

    def test_round_trips_a_real_lock(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "flake.lock"
            _ = path.write_text(json.dumps(LOCK))
            self.assertEqual(lockfile.load_lock(path), LOCK)


if __name__ == "__main__":
    _ = unittest.main()
