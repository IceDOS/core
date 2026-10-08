from __future__ import annotations

import os
import re
import shutil
from collections.abc import Sequence
from datetime import datetime
from pathlib import Path

from .context import BuildEnv, RebuildContext
from .options import Options
from .runner import ACTIVATING_ACTIONS
from .term import DIM_GREEN, clr_line, paint

# Read by config-rollback, config-history, config-diff, status and the gc in nh.nix.
CONFIG_SET_MARKER = ".config-set"
GENERATIONS_DIR = "generations"
SYSTEM_PROFILE = Path("/nix/var/nix/profiles/system")

_GENERATION_LINK = re.compile(r"system-(\d+)-link")


# Same shape as `date -Is`, which every existing snapshot folder is named with.
def timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _parse_stamp(name: str) -> datetime | None:
    try:
        stamp = datetime.fromisoformat(name)
    except ValueError:
        return None
    return stamp if stamp.tzinfo is not None else None


# Oldest first by the time in the name; mtime moves when a folder is rewritten,
# and plain name order breaks across a DST change.
def snapshot_folders(cache_dir: Path) -> list[Path]:
    if not cache_dir.is_dir():
        return []
    stamped: list[tuple[datetime, Path]] = []
    for entry in cache_dir.iterdir():
        stamp = _parse_stamp(entry.name)
        if stamp is not None and entry.is_dir():
            stamped.append((stamp, entry))
    stamped.sort(key=lambda pair: (pair[0], pair[1].name))
    return [folder for _, folder in stamped]


def latest_config_snapshot(cache_dir: Path) -> Path | None:
    for folder in reversed(snapshot_folders(cache_dir)):
        if (folder / CONFIG_SET_MARKER).is_file():
            return folder
    return None


# Two missing files count as equal, since config.toml is optional.
def _same(a: Path, b: Path) -> bool:
    if not (a.is_file() and b.is_file()):
        return a.is_file() == b.is_file()
    return a.read_bytes() == b.read_bytes()


def _tomls(root: Path) -> set[Path]:
    if not root.is_dir():
        return set()
    return {p.relative_to(root) for p in root.rglob("*.toml") if p.is_file()}


def config_set_changed(
    snapshot: Path | None, config_root: Path, config_dirs: Sequence[str]
) -> bool:
    if snapshot is None:
        return True
    if not _same(config_root / "config.toml", snapshot / "config.toml"):
        return True
    for d in config_dirs:
        live, saved = config_root / d, snapshot / d
        for rel in _tomls(live) | _tomls(saved):
            if not _same(live / rel, saved / rel):
                return True
    return False


# Hidden .*.toml files are included, so rollback restores the set exactly.
def snapshot_config_set(
    cache_dir: Path, folder: Path, config_root: Path, config_dirs: Sequence[str]
) -> bool:
    if not config_set_changed(
        latest_config_snapshot(cache_dir), config_root, config_dirs
    ):
        return False
    folder.mkdir(parents=True, exist_ok=True)
    (folder / CONFIG_SET_MARKER).touch()
    if (config_root / "config.toml").is_file():
        _ = shutil.copy2(config_root / "config.toml", folder / "config.toml")
    for d in config_dirs:
        for rel in sorted(_tomls(config_root / d)):
            target = folder / d / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            _ = shutil.copy2(config_root / d / rel, target)
    return True


def _newest_copy(cache_dir: Path, name: str) -> Path | None:
    for folder in reversed(snapshot_folders(cache_dir)):
        if (folder / name).is_file():
            return folder / name
    return None


# Caches each (source, name) pair whose content differs from its newest copy.
def cache_files(
    cache_dir: Path, folder: Path, files: Sequence[tuple[Path, str]]
) -> list[str]:
    cached: list[str] = []
    for source, name in files:
        if not source.is_file():
            continue
        previous = _newest_copy(cache_dir, name)
        if previous is not None and _same(source, previous):
            continue
        folder.mkdir(parents=True, exist_ok=True)
        _ = shutil.copy2(source, folder / name)
        cached.append(name)
    return cached


def current_generation(profile: Path = SYSTEM_PROFILE) -> str | None:
    try:
        target = os.readlink(profile)
    except OSError:
        return None
    match = _GENERATION_LINK.fullmatch(Path(target).name)
    return match.group(1) if match else None


def record_generation(cache_dir: Path, generation: str, snapshot: str) -> None:
    pointers = cache_dir / GENERATIONS_DIR
    pointers.mkdir(parents=True, exist_ok=True)
    _ = (pointers / generation).write_text(snapshot)


def record_rebuild(
    env: BuildEnv,
    opts: Options,
    ctx: RebuildContext,
    *,
    stamp: str | None = None,
    profile: Path = SYSTEM_PROFILE,
    previous_generation: str | None = None,
) -> None:
    if env.config_root is None:
        return
    cache_dir = env.state_dir / ".cache"
    # One folder per run keeps a config set next to the flake files it built.
    folder = cache_dir / (stamp or timestamp())

    names: list[str] = []
    if snapshot_config_set(cache_dir, folder, env.config_root, ctx.config_dirs):
        names.append("config set")
    names += cache_files(
        cache_dir,
        folder,
        [
            (env.config_root / "flake.lock", "flake.lock.config"),
            (env.config_root / "flake.nix", "flake.nix.config"),
            (env.state_dir / "flake.lock", "flake.lock.state"),
            (env.state_dir / "flake.nix", "flake.nix.state"),
        ],
    )
    if names:
        joined = ", ".join(names)
        print(f"{clr_line()}{paint(DIM_GREEN, '>')} Caching {joined}", flush=True)

    # Only switch/boot mint a generation, so only they record which snapshot
    # built it (for `icedos configuration rollback`).
    if opts.action not in ACTIVATING_ACTIONS:
        return
    generation = current_generation(profile)
    # The profile did not move (remote --target, declined --ask, same closure).
    if generation is None or generation == previous_generation:
        return
    snapshot = latest_config_snapshot(cache_dir)
    if snapshot is not None:
        record_generation(cache_dir, generation, snapshot.name)
