from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class BuildEnv:
    root: Path
    config_root: Path | None
    state_dir: Path
    inputs_prefix: str


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
