from __future__ import annotations

import atexit
import os
import shutil
import tempfile
from pathlib import Path

from .context import BuildEnv
from .genflake import generate_flake
from .lockfile import (
    input_is_string,
    input_locked_path,
    load_lock,
    nested_path_inputs,
    path_inputs,
    path_nodes,
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


def maybe_re_exec_update_core(
    env: BuildEnv, opts: Options, previous_arguments: list[str]
) -> None:
    if not (opts.update_core or opts.update_core_only):
        return
    if os.environ.get("skip_update_core"):
        return
    if not env.config_root:
        return

    if opts.update_core:
        run(["nix", "flake", "update", "--refresh"], cwd=env.config_root, check=True)
    else:
        run(
            ["nix", "flake", "update", "icedos", "--refresh"],
            cwd=env.config_root,
            check=True,
        )

    new_env = os.environ.copy()
    new_env["skip_update_core"] = "1"
    # `path:.` resolves against the process cwd, which execvpe inherits; the
    # `cwd=` above only applied to the `nix flake update` child.
    os.chdir(env.config_root)
    os.execvpe("nix", ["nix", "run", "path:.", "--", *previous_arguments], new_env)


def _sync_lock(lock_dir: Path, state_dir: Path) -> None:
    lock_file = lock_dir / "flake.lock"
    if lock_file.exists():
        _ = shutil.copy2(lock_file, state_dir / "flake.lock")
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

    if opts.update_core:
        ignored(["nix", "flake", "update", "icedos-core", "--refresh"], cwd=lock_dir)

    if opts.update_all:
        run(["nix", "flake", "update", "--refresh"], cwd=lock_dir, check=True)
    elif opts.update_repos_inputs:
        lock = load_lock(lock_dir / "flake.lock")
        for sub in subflakes_from_lock(lock):
            for name in string_inputs(lock, sub):
                ignored(
                    ["nix", "flake", "update", f"{sub}/{name}", "--refresh"],
                    cwd=lock_dir,
                )

    if opts.state_inputs:
        lock = load_lock(lock_dir / "flake.lock")
        valid_inputs: list[str] = []
        for name in opts.state_inputs:
            if name.startswith(env.inputs_prefix + "-"):
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
            {"ICEDOS_UPDATE": "", "ICEDOS_UPDATE_MODULE_INPUTS": ""},
        )
        sync_dir(env.state_dir, lock_dir)
        run(["nix", "flake", "lock"], cwd=lock_dir, check=True)

    _sync_lock(lock_dir, env.state_dir)

    if opts.genflake_only:
        return

    shutil.rmtree(lock_dir, ignore_errors=True)
