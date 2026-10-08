from __future__ import annotations

import os
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

from .util import read_json

# Set only by the `icedos rebuild` shim (modules/rebuild.nix); unset means raw mode.
CONTEXT_ENV = "ICEDOS_REBUILD_CONTEXT"

HOOK_NAMES = ("preRebuild", "postRebuild", "preUpdate", "postUpdate")

DEFAULT_CONFIG_DIRS = ("configs",)


@dataclass(frozen=True)
class BuildEnv:
    root: Path
    config_root: Path | None
    state_dir: Path
    inputs_prefix: str


@dataclass(frozen=True)
class RebuildContext:
    config_dirs: tuple[str, ...]
    hooks: Mapping[str, tuple[str, ...]]

    def hook_scripts(self, name: str) -> tuple[str, ...]:
        return self.hooks.get(name, ())


def from_environment() -> BuildEnv:
    root = Path(os.environ.get("ICEDOS_ROOT", Path(__file__).resolve().parent.parent))
    state_dir = Path(os.environ.get("ICEDOS_STATE_DIR", root / ".state"))
    config_root_raw = os.environ.get("ICEDOS_CONFIG_ROOT")
    config_root = Path(config_root_raw) if config_root_raw else None
    return BuildEnv(
        root=root,
        config_root=config_root,
        state_dir=state_dir,
        inputs_prefix=os.environ.get("ICEDOS_INPUTS_PREFIX", "icedos"),
    )


def _invalid(path: str, detail: str) -> NoReturn:
    print(f"error: invalid rebuild context {path}: {detail}", file=sys.stderr)
    raise SystemExit(1)


def _strings(value: object, path: str, key: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        _invalid(path, f"{key} must be a list of strings")
    items = [item for item in value if isinstance(item, str)]
    if len(items) != len(value):
        _invalid(path, f"{key} must be a list of strings")
    return tuple(items)


# The file may come from an older system, so missing keys get defaults and
# unknown keys are ignored.
def load_rebuild_context(environ: Mapping[str, str]) -> RebuildContext | None:
    raw = environ.get(CONTEXT_ENV)
    if not raw:
        return None
    try:
        data = read_json(Path(raw))
    except (OSError, ValueError) as exc:
        _invalid(raw, str(exc))
    if not isinstance(data, dict):
        _invalid(raw, "expected a JSON object")

    config_dirs: tuple[str, ...] = DEFAULT_CONFIG_DIRS
    if "configDirs" in data:
        dirs = _strings(data["configDirs"], raw, "configDirs")
        # Nix joins these as "${configRoot}/${dir}", so "/x" still means <root>/x.
        stripped = (d.lstrip("/") for d in dirs)
        config_dirs = tuple(d for d in stripped if d)

    hooks_raw = data.get("hooks", {})
    if not isinstance(hooks_raw, dict):
        _invalid(raw, "hooks must be an object")
    hooks = {
        name: _strings(hooks_raw[name], raw, f"hooks.{name}")
        for name in HOOK_NAMES
        if name in hooks_raw
    }
    return RebuildContext(config_dirs=config_dirs, hooks=hooks)
