from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path

from .context import CONTEXT_ENV, RebuildContext
from .term import log_warn

# The shim passes the invoking shell's value of each RESTORED_VARS entry under
# this prefix; an empty value means the variable was unset.
ORIG_PREFIX = "ICEDOS_ORIG_"

# Overridden by the build app or the orchestrator before any hook runs.
RESTORED_VARS = ("PATH", "PYTHONPATH", "NIX_CONFIG")

# NIX_CONFIG is dropped too, because the orchestrator's copy carries the token.
_DROPPED_VARS = frozenset(
    {"ICEDOS_GITHUB_TOKEN", "NIX_CONFIG", "skip_update_core", CONTEXT_ENV}
)


def hook_env(environ: Mapping[str, str], *, hooks_only: bool) -> dict[str, str]:
    env = {
        key: value
        for key, value in environ.items()
        if key not in _DROPPED_VARS and not key.startswith(ORIG_PREFIX)
    }
    for name in RESTORED_VARS:
        original = environ.get(ORIG_PREFIX + name)
        if original is None:
            continue
        if original:
            env[name] = original
        else:
            _ = env.pop(name, None)
    if hooks_only:
        env["ICEDOS_HOOKS_ONLY"] = "1"
    return env


# A failing hook warns and the rebuild goes on; Ctrl-C stops the whole rebuild.
def run_hooks(
    ctx: RebuildContext, name: str, *, cwd: Path, hooks_only: bool = False
) -> None:
    scripts = ctx.hook_scripts(name)
    if not scripts:
        return
    env = hook_env(os.environ, hooks_only=hooks_only)
    for i, script in enumerate(scripts):
        # Our buffered output has to land before the hook's when stdout is a pipe.
        sys.stdout.flush()
        try:
            proc = subprocess.run([script], cwd=cwd, env=env, check=False)
        except KeyboardInterrupt:
            print(f"interrupted during {name} hook {i}", file=sys.stderr)
            raise SystemExit(130) from None
        except OSError as exc:
            log_warn(f"{name} hook {i} could not start: {exc}")
            continue
        if proc.returncode != 0:
            log_warn(f"{name} hook {i} exited with code {proc.returncode}")
