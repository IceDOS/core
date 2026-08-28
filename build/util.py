from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import TypeAlias, cast

# Recursive JSON value, so parsed flake.lock / cache data stays typed without Any.
JSON: TypeAlias = str | int | float | bool | None | list["JSON"] | dict[str, "JSON"]


def _full_env(env: Mapping[str, str] | None) -> dict[str, str]:
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    return full_env


def run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    stderr: int | None = None,
) -> None:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=_full_env(env),
        check=False,
        stderr=stderr,
        text=True,
    )
    if check and proc.returncode != 0:
        raise SystemExit(proc.returncode)


# Captures stdout; stderr stays on the terminal like the old $(...) substitutions.
def capture(
    cmd: list[str], *, cwd: Path | None = None, env: Mapping[str, str] | None = None
) -> str:
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=_full_env(env),
        check=False,
        stdout=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return proc.stdout or ""


def ignored(cmd: list[str], *, cwd: Path | None = None) -> None:
    run(cmd, cwd=cwd, check=False, stderr=subprocess.DEVNULL)


def sync_dir(src: Path, dst: Path) -> None:
    _ = shutil.copytree(
        src,
        dst,
        dirs_exist_ok=True,
        symlinks=True,
        ignore=shutil.ignore_patterns(".cache"),
    )


def read_json(path: Path) -> JSON:
    with path.open() as f:
        return cast(JSON, json.load(f))


def write_json(path: Path, value: JSON) -> None:
    _ = path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        json.dump(value, f, ensure_ascii=False)


def write_text(path: Path, text: str) -> None:
    _ = path.parent.mkdir(parents=True, exist_ok=True)
    _ = path.write_text(text)


def warn(message: str) -> None:
    print(message, file=sys.stderr)
