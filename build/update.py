from __future__ import annotations

import atexit
import json
import os
import shutil
import subprocess
import tempfile
from collections.abc import Iterable
from pathlib import Path
from typing import cast

from .context import BuildEnv
from .genflake import CachePin, cache_unpin_info, generate_flake
from .lockfile import (
    genflake_controlled,
    input_is_string,
    input_locked_path,
    load_lock,
    nested_path_inputs,
    nested_string_inputs,
    path_inputs,
    path_nodes,
    root_string_inputs,
    select_update_inputs,
    string_inputs,
    subflakes_from_lock,
)
from .options import Options
from .util import JSON, capture, ignored, read_json, run, sync_dir, warn, write_text

# Live cache unpins, absent = every cache-pinned input follows the cache pin.
CACHE_UNPIN_FILE = "cache-unpin.json"


def refresh_config_root_paths(env: BuildEnv, opts: Options) -> None:
    if opts.update_core or not env.config_root:
        return
    lock_path = env.config_root / "flake.lock"
    if not lock_path.exists():
        return
    lock = load_lock(lock_path)
    for name in path_nodes(lock):
        ignored(["nix", "flake", "update", name], cwd=env.config_root)


def validate_update_except(env: BuildEnv, opts: Options) -> None:
    if not opts.update_except:
        return
    state_lock_path = env.state_dir / "flake.lock"
    if not state_lock_path.exists():
        warn("warning: no state flake.lock yet; --update-except will have no effect")
        return

    state_lock = load_lock(state_lock_path)
    valid_names = set(root_string_inputs(state_lock)) | set(nested_string_inputs(state_lock))
    if env.config_root:
        config_lock_path = env.config_root / "flake.lock"
        if config_lock_path.exists():
            valid_names |= set(root_string_inputs(load_lock(config_lock_path)))

    subs = set(subflakes_from_lock(state_lock))
    for name in opts.update_except:
        if name in subs:
            warn(f"error: '{name}' is a sub-flake root and cannot be excluded")
            raise SystemExit(1)
        if name not in valid_names:
            names_str = ", ".join(sorted(valid_names))
            warn(f"error: '{name}' is not an input of the state or config flake.lock\nvalid inputs: {names_str}")
            raise SystemExit(1)


def unpin_file(env: BuildEnv) -> Path:
    return env.state_dir / CACHE_UNPIN_FILE


class MetadataUnavailable(Exception):
    """A `nix flake metadata` lookup a soft caller can survive."""


def load_unpins(env: BuildEnv) -> tuple[dict[str, dict[str, JSON]], bool]:
    """Live unpins from cache-unpin.json, plus whether the file needs a rewrite.

    Never aborts: genflake applies whatever the file holds, so an unusable file
    or entry is reported once and dropped here, and `dirty` asks the caller to
    rewrite it (deleting it when nothing survives).
    """
    path = unpin_file(env)
    if not path.exists():
        return {}, False
    try:
        data = read_json(path)
    except (OSError, ValueError) as exc:
        warn(f"warning: {path} cannot be read ({exc}); ignoring every cache unpin")
        return {}, True
    if not isinstance(data, dict):
        warn(f"warning: {path} is not a JSON object; ignoring every cache unpin")
        return {}, True

    entries: dict[str, dict[str, JSON]] = {}
    dirty = False
    for name, entry in data.items():
        detail = ""
        if not isinstance(entry, dict):
            detail = "it is not an object"
        elif not isinstance(entry.get("rev"), str) or not entry.get("rev"):
            detail = "it has no rev"
        elif isinstance(entry.get("lastModified"), bool) or not isinstance(
            entry.get("lastModified"), int
        ):
            detail = "it has no integer lastModified"
        if detail:
            warn(f"warning: {path}: dropping '{name}' ({detail})")
            dirty = True
            continue
        entries[name] = cast("dict[str, JSON]", entry)
    return entries, dirty


def _write_unpins(env: BuildEnv, entries: dict[str, dict[str, JSON]]) -> None:
    path = unpin_file(env)
    if not entries:
        path.unlink(missing_ok=True)
        return
    # Atomic: genflake reads this file during the same run, so no torn write may land.
    write_text(path, json.dumps(entries, indent=2, sort_keys=True) + "\n")


def _cache_rev_url(pin: CachePin) -> str:
    """`<stem>/<rev>`, with any query kept last like genflake's `_appendRevSuffix`."""
    stem, sep, query = pin.url.rstrip("/").partition("?")
    return f"{stem}/{pin.rev}" + (f"?{query}" if sep else "")


def _flake_metadata(
    url: str, *, refresh: bool = True, soft: bool = False
) -> tuple[str, int]:
    """`locked.rev`/`locked.lastModified` of `url`.

    A `soft` caller (the cache-date lookup) gets `MetadataUnavailable` and keeps
    its entry; the explicit unpin resolution aborts on the same failures.
    """
    cmd = ["nix", "flake", "metadata", "--json"]
    if refresh:
        cmd.append("--refresh")
    cmd.append(url)
    detail = ""
    try:
        data: JSON = json.loads(capture(cmd))
    except SystemExit:
        detail = f"'nix flake metadata {url}' failed"
    except ValueError:
        detail = f"'nix flake metadata {url}' returned invalid JSON"
    else:
        locked = data.get("locked") if isinstance(data, dict) else None
        rev = locked.get("rev") if isinstance(locked, dict) else None
        mtime = locked.get("lastModified") if isinstance(locked, dict) else None
        if not isinstance(rev, str) or not rev:
            detail = f"'nix flake metadata {url}' returned no locked rev"
        elif isinstance(mtime, bool) or not isinstance(mtime, int):
            detail = f"'nix flake metadata {url}' returned no locked lastModified"
        else:
            return rev, mtime
    if soft:
        raise MetadataUnavailable(detail)
    warn(f"error: {detail}")
    raise SystemExit(1)


def _cache_time(
    name: str, pin: CachePin, cache_times: dict[str, int | None]
) -> int | None:
    """The cache's date for the pinned rev, one metadata lookup at most per name."""
    if name in cache_times:
        return cache_times[name]
    value = pin.last_modified
    if value is None:
        try:
            _rev, value = _flake_metadata(_cache_rev_url(pin), refresh=False, soft=True)
        except MetadataUnavailable:
            warn(f"warning: cannot read the cache date for '{name}'; keeping its unpin")
            value = None
    cache_times[name] = value
    return value


def _expired(
    name: str,
    entry: dict[str, JSON],
    pins: dict[str, CachePin],
    cache_times: dict[str, int | None],
) -> bool:
    pin = pins.get(name)
    # No longer cache-pinned at all (pinInputs off, input removed, ...).
    if pin is None:
        return True
    if pin.rev == entry.get("rev"):
        return True
    cache_time = _cache_time(name, pin, cache_times)
    if cache_time is None:
        return False
    mtime = entry.get("lastModified")
    return isinstance(mtime, int) and cache_time >= mtime


def _rollback_note(opts: Options) -> str:
    """Why an unpin recorded now will not survive this run (mirrors `persist`)."""
    if opts.dry:
        return " (rolled back: --dry)"
    # --lock-only persists (main.py's `persist`), so only a bare --genflake-only
    # throws the recorded unpin away.
    if opts.genflake_only and not (opts.keep_flake or opts.lock_only):
        return " (rolled back: --genflake-only)"
    return ""


def _merge_unpins(
    opts: Options,
    entries: dict[str, dict[str, JSON]],
    pins: dict[str, CachePin],
    cache_times: dict[str, int | None],
) -> None:
    selected = sorted(pins) if opts.unpin else []
    for name in opts.unpin_names:
        if name not in pins:
            valid = ", ".join(sorted(pins)) if pins else "(none)"
            warn(f"error: '{name}' is not a cache-pinned input\nvalid names: {valid}")
            raise SystemExit(1)
        if name not in selected:
            selected.append(name)

    skipped = [n for n in selected if n in opts.update_except]
    for name in skipped:
        warn(f"warning: --update-except keeps '{name}' at its locked rev; not unpinning it")
    selected = [n for n in selected if n not in opts.update_except]
    if not selected:
        if skipped:
            warn("warning: every selected input is excluded by --update-except; nothing unpinned")
        else:
            warn("warning: no cache-pinned inputs to unpin")
        return

    note = _rollback_note(opts)
    for name in selected:
        pin = pins[name]
        # `url` is rev-less (and nixpkgs' is the cache's channel); `latestUrl`
        # carries the branch/ref the unpin must track.
        latest_rev, latest_time = _flake_metadata(pin.latest_url)
        at_pin = pin.rev == latest_rev
        if not at_pin:
            cache_time = _cache_time(name, pin, cache_times)
            at_pin = cache_time is not None and cache_time >= latest_time
        if at_pin:
            warn(f"info: {name} is already at the cache pin; not unpinning it")
            continue
        previous = entries.get(name)
        old = previous.get("rev") if previous is not None else None
        entries[name] = {"rev": latest_rev, "lastModified": latest_time}
        if isinstance(old, str) and old:
            if old == latest_rev:
                warn(f"info: {name} is already at its latest rev ({latest_rev[:7]}){note}")
            else:
                warn(f"info: unpinned {name} at {latest_rev[:7]} (was {old[:7]}){note}")
        else:
            warn(f"info: unpinned {name} at {latest_rev[:7]}{note}")


def prepare_unpins(
    env: BuildEnv,
    opts: Options,
    trace: list[str],
    unpins: tuple[dict[str, dict[str, JSON]], bool] | None = None,
) -> None:
    """Prune unpins the cache caught up with, then merge the requested revs.

    Runs before generate_flake: genflake applies every entry in the file as-is, so
    an expired or malformed entry must be gone by then. `cacheUnpinInfo` forces
    module resolution, so it is evaluated once per rebuild while an unpin is live
    or requested, never per name.
    """
    if not env.config_root:
        return

    entries, dirty = load_unpins(env) if unpins is None else (dict(unpins[0]), unpins[1])
    want_unpin = opts.unpin or bool(opts.unpin_names)
    if not entries and not want_unpin:
        # A malformed file still has to go, so the next reader sees no unpins.
        if dirty:
            _write_unpins(env, {})
        return

    pins = cache_unpin_info(env, trace)
    cache_times: dict[str, int | None] = {}

    dropped = False
    for name in sorted(entries):
        if not _expired(name, entries[name], pins, cache_times):
            continue
        if name in pins:
            warn(f"info: cache caught up with '{name}'; dropping its unpin")
        else:
            warn(f"info: '{name}' is no longer cache-pinned; dropping its unpin")
        del entries[name]
        dropped = True

    before = dict(entries)
    if want_unpin:
        _merge_unpins(opts, entries, pins, cache_times)
    if dropped or dirty or entries != before:
        _write_unpins(env, entries)


def update_cache_pin(
    env: BuildEnv,
    opts: Options,
    pinned: list[str],
    unpinned: Iterable[str] = (),
) -> list[str]:
    live = set(unpinned)
    requested = [n for n in opts.state_inputs if n in pinned]
    if not requested:
        return []
    if opts.update_core and not any(p in opts.update_except for p in pinned):
        return []
    if not env.config_root:
        return []

    for name in requested:
        if name in live:
            warn(
                f"info: {name} is unpinned; the cache pin moves but the unpin keeps "
                "its rev until the cache catches up"
            )
        else:
            warn(f"info: {name} is cache-pinned; updating the cache pin (icedos/cache-server) instead")
    # An unpin is never frozen by this path: freezing reads the state lock, which
    # still holds the previous rev, and would undo a re-resolve in the same run.
    kept = [n for n in pinned if n not in opts.state_inputs and n not in live]
    if kept:
        warn(
            f"warning: updating {', '.join(requested)} but keeping {', '.join(kept)} at its locked rev; "
            "name both to keep them matched"
        )

    run(["nix", "flake", "update", "icedos/cache-server", "--refresh"], cwd=env.config_root, check=True)
    return kept

# The re-exec'd child already reported its own failure; the parent must not repeat it.
class ReExecExited(SystemExit):
    pass


def maybe_re_exec_update_core(
    env: BuildEnv, opts: Options, previous_arguments: list[str]
) -> None:
    if not (opts.update_core or opts.update_core_only):
        return
    if os.environ.get("skip_update_core"):
        return
    if not env.config_root:
        return

    if opts.update_core and opts.update_except:
        names = select_update_inputs(
            root_string_inputs(load_lock(env.config_root / "flake.lock")),
            opts.update_except,
        )
        if names:
            run(["nix", "flake", "update", *names, "--refresh"], cwd=env.config_root, check=True)
        else:
            return
    elif opts.update_core:
        run(["nix", "flake", "update", "--refresh"], cwd=env.config_root, check=True)
    else:
        run(
            ["nix", "flake", "update", "icedos", "--refresh"],
            cwd=env.config_root,
            check=True,
        )

    new_env = os.environ.copy()
    new_env["skip_update_core"] = "1"
    new_env["ICEDOS_TXN"] = "1"
    proc = subprocess.Popen(
        ["nix", "run", "path:.", "--", *previous_arguments],
        cwd=env.config_root,
        env=new_env,
    )
    while True:
        try:
            raise ReExecExited(proc.wait())
        except KeyboardInterrupt:
            continue


def _sync_lock(lock_dir: Path, state_dir: Path) -> None:
    lock_file = lock_dir / "flake.lock"
    if lock_file.exists():
        tmp_target = state_dir / "flake.lock.icedos-tmp"
        _ = shutil.copy2(lock_file, tmp_target)
        os.replace(tmp_target, state_dir / "flake.lock")
    else:
        warn("warning: no flake.lock in detached lock dir — nothing to sync")


def prepare_lock(env: BuildEnv, opts: Options, trace: list[str]) -> None:
    lock_dir = Path(tempfile.mkdtemp(prefix="icedos-lock-", suffix="-0"))
    _ = atexit.register(shutil.rmtree, lock_dir, ignore_errors=True)
    sync_dir(env.state_dir, lock_dir)

    first_lock = not (lock_dir / "flake.lock").exists()

    run(["nix", "flake", "lock"], cwd=lock_dir, check=True)

    needs_prefetch = (
        first_lock
        or opts.update_core
        or opts.update_repos
        or opts.update_repos_inputs
        or bool(opts.state_inputs)
        or bool(opts.repos_select)
    )
    if needs_prefetch:
        run(["nix", "flake", "prefetch-inputs"], cwd=lock_dir, check=True)

    lock = load_lock(lock_dir / "flake.lock")
    for name in path_inputs(lock):
        locked_path = input_locked_path(lock, name)
        if locked_path.startswith("/nix/store/"):
            continue
        ignored(["nix", "flake", "update", name], cwd=lock_dir)

    for sub in subflakes_from_lock(lock):
        for name in nested_path_inputs(lock, sub):
            ignored(["nix", "flake", "update", f"{sub}/{name}"], cwd=lock_dir)

    if opts.update_core and "icedos" not in opts.update_except:
        ignored(["nix", "flake", "update", "icedos-core", "--refresh"], cwd=lock_dir)

    if opts.update_all and opts.update_except:
        lock = load_lock(lock_dir / "flake.lock")
        subs = set(subflakes_from_lock(lock))
        names = select_update_inputs([n for n in root_string_inputs(lock) if n not in subs], opts.update_except)
        if names:
            run(["nix", "flake", "update", *names, "--refresh"], cwd=lock_dir, check=True)
    elif opts.update_all:
        run(["nix", "flake", "update", "--refresh"], cwd=lock_dir, check=True)

    if opts.update_repos_inputs and (opts.update_except or not opts.update_all):
        lock = load_lock(lock_dir / "flake.lock")
        for sub in subflakes_from_lock(lock):
            for name in string_inputs(lock, sub):
                if f"{sub}/{name}" in opts.update_except:
                    continue
                ignored(
                    ["nix", "flake", "update", f"{sub}/{name}", "--refresh"],
                    cwd=lock_dir,
                )

    if opts.state_inputs:
        lock = load_lock(lock_dir / "flake.lock")
        valid_inputs: list[str] = []
        for name in opts.state_inputs:
            if name in opts.freeze_inputs or name in opts.cache_pinned:
                continue
            if genflake_controlled(lock, name, env.inputs_prefix):
                msg = f"skipping '{name}' — controlled by genflake, use --update-repos to update"
                warn(f"warning: {msg}")
                continue
            if not input_is_string(lock, name):
                warn(f"error: '{name}' is not a declared input in the state flake.lock")
                raise SystemExit(1)
            valid_inputs.append(name)
        for name in valid_inputs:
            run(["nix", "flake", "update", name], cwd=lock_dir, check=True)

    if opts.update_repos_inputs or opts.update_all:
        _sync_lock(lock_dir, env.state_dir)
        generate_flake(
            env,
            trace,
            {
                "ICEDOS_UPDATE": "",
                "ICEDOS_UPDATE_MODULE_INPUTS": "",
                "ICEDOS_FREEZE_INPUTS": " ".join(opts.freeze_inputs),
            },
        )
        sync_dir(env.state_dir, lock_dir)
        run(["nix", "flake", "lock"], cwd=lock_dir, check=True)

    _sync_lock(lock_dir, env.state_dir)

    if opts.genflake_only:
        return

    shutil.rmtree(lock_dir, ignore_errors=True)
