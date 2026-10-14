from __future__ import annotations

from pathlib import Path

from .util import JSON, read_json


def _as_dict(value: JSON) -> dict[str, JSON]:
    return value if isinstance(value, dict) else {}


def _as_str(value: JSON) -> str:
    return value if isinstance(value, str) else ""


def load_lock(path: Path) -> dict[str, JSON]:
    if not path.exists():
        return {}
    try:
        return _as_dict(read_json(path))
    except (ValueError, OSError):
        return {}


def _nodes(lock: dict[str, JSON]) -> dict[str, JSON]:
    return _as_dict(lock.get("nodes"))


def _root_inputs(lock: dict[str, JSON]) -> dict[str, JSON]:
    return _as_dict(_as_dict(_nodes(lock).get("root")).get("inputs"))


def _node(lock: dict[str, JSON], key: str) -> dict[str, JSON]:
    return _as_dict(_nodes(lock).get(key))


def _locked(lock: dict[str, JSON], key: str) -> dict[str, JSON]:
    return _as_dict(_node(lock, key).get("locked"))


def path_nodes(lock: dict[str, JSON]) -> list[str]:
    return [
        key
        for key, node in _nodes(lock).items()
        if _as_dict(_as_dict(node).get("locked")).get("type") == "path"
    ]


def path_inputs(lock: dict[str, JSON]) -> list[str]:
    return [
        key
        for key, value in _root_inputs(lock).items()
        if isinstance(value, str) and _locked(lock, value).get("type") == "path"
    ]


def input_locked_path(lock: dict[str, JSON], input_name: str) -> str:
    key = _root_inputs(lock).get(input_name)
    if not isinstance(key, str):
        return ""
    return _as_str(_locked(lock, key).get("path"))


def subflakes_from_lock(lock: dict[str, JSON]) -> list[str]:
    result: list[str] = []
    for key, value in _root_inputs(lock).items():
        if not isinstance(value, str):
            continue
        locked = _locked(lock, value)
        if locked.get("type") != "path":
            continue
        path = _as_str(locked.get("path"))
        if path.startswith("/nix/store/") and path.endswith(f"-{key}-subflake"):
            result.append(key)
    return result


def nested_path_inputs(lock: dict[str, JSON], subflake: str) -> list[str]:
    key = _root_inputs(lock).get(subflake)
    if not isinstance(key, str):
        return []
    result: list[str] = []
    for input_name, locked_key in _as_dict(_node(lock, key).get("inputs")).items():
        if not isinstance(locked_key, str):
            continue
        locked = _locked(lock, locked_key)
        if locked.get("type") != "path":
            continue
        if _as_str(locked.get("path")).startswith("/nix/store/"):
            continue
        result.append(input_name)
    return result


def string_inputs(lock: dict[str, JSON], subflake: str) -> list[str]:
    key = _root_inputs(lock).get(subflake)
    if not isinstance(key, str):
        return []
    return [
        name
        for name, value in _as_dict(_node(lock, key).get("inputs")).items()
        if isinstance(value, str)
    ]


def input_is_string(lock: dict[str, JSON], input_name: str) -> bool:
    return isinstance(_root_inputs(lock).get(input_name), str)


def locked_revs(lock: dict[str, JSON]) -> dict[str, str]:
    """Root and <sub>/<name> string inputs mapped to their locked rev ("" when unrevved)."""
    revs: dict[str, str] = {}
    for name, node_key in _root_inputs(lock).items():
        if isinstance(node_key, str):
            revs[name] = _as_str(_locked(lock, node_key).get("rev"))

    for sub in subflakes_from_lock(lock):
        sub_key = _root_inputs(lock).get(sub)
        if isinstance(sub_key, str):
            for name, node_key in _as_dict(_node(lock, sub_key).get("inputs")).items():
                if isinstance(node_key, str):
                    revs[f"{sub}/{name}"] = _as_str(_locked(lock, node_key).get("rev"))

    return revs


def rev_changes(old: dict[str, JSON], new: dict[str, JSON]) -> list[tuple[str, str, str]]:
    """(name, old_rev, new_rev) for every input whose rev differs, added or removed, sorted by name."""
    old_revs = locked_revs(old)
    new_revs = locked_revs(new)
    all_names = sorted(set(old_revs.keys()) | set(new_revs.keys()))
    changes: list[tuple[str, str, str]] = []
    for name in all_names:
        o = old_revs.get(name, "")
        n = new_revs.get(name, "")
        if o != n:
            changes.append((name, o, n))
    return changes


def genflake_controlled(lock: dict[str, JSON], name: str, prefix: str) -> bool:
    if name in subflakes_from_lock(lock):
        return True
    return name.startswith(f"{prefix}-") and not name.startswith(f"{prefix}-overlay-")


def root_string_inputs(lock: dict[str, JSON]) -> list[str]:
    return [name for name, value in _root_inputs(lock).items() if isinstance(value, str)]


def nested_string_inputs(lock: dict[str, JSON]) -> list[str]:
    return [f"{sub}/{name}" for sub in subflakes_from_lock(lock) for name in string_inputs(lock, sub)]


def select_update_inputs(names: list[str], excluded: list[str]) -> list[str]:
    return [n for n in names if n not in excluded]
