from __future__ import annotations

import atexit
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from .context import BuildEnv
from .genflake import generate_flake
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
from .util import ignored, run, sync_dir, warn


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


def update_cache_pin(env: BuildEnv, opts: Options, pinned: list[str]) -> list[str]:
    requested = [n for n in opts.state_inputs if n in pinned]
    if not requested:
        return []
    if opts.update_core and not any(p in opts.update_except for p in pinned):
        return []
    if not env.config_root:
        return []

    for name in requested:
        warn(f"info: {name} is cache-pinned; updating the cache pin (icedos/cache-server) instead")
    if len(requested) < len(pinned):
        kept = [n for n in pinned if n not in opts.state_inputs]
        warn(
            f"warning: updating {', '.join(requested)} but keeping {', '.join(kept)} at its locked rev; "
            "name both to keep them matched"
        )

    run(["nix", "flake", "update", "icedos/cache-server", "--refresh"], cwd=env.config_root, check=True)
    return [n for n in pinned if n not in opts.state_inputs]


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
            raise SystemExit(proc.wait())
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
