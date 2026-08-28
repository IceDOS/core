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
