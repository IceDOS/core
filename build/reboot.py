from __future__ import annotations

import filecmp
import subprocess
import sys
from pathlib import Path

from .options import Options
from .term import DIM_GREEN, PURPLE, clr_line, paint

BOOTED_SYSTEM = Path("/run/booted-system")
CURRENT_SYSTEM = Path("/run/current-system")
REBOOT_COMPONENTS = ("kernel", "initrd")


def reboot_reasons(booted: Path, current: Path) -> list[str]:
    reasons: list[str] = []
    for component in REBOOT_COMPONENTS:
        try:
            old = (booted / component).resolve(strict=True)
            new = (current / component).resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if old != new and not filecmp.cmp(old, new, shallow=False):
            reasons.append(component)
    return reasons


def _interactive() -> bool:
    return sys.stdin.isatty()


# EOF and Ctrl-C at the prompt both count as "no".
def _confirm(prompt: str) -> bool:
    try:
        answer = input(prompt)
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    return answer.strip().lower() in ("y", "yes")


def offer_reboot(
    opts: Options,
    *,
    booted: Path = BOOTED_SYSTEM,
    current: Path = CURRENT_SYSTEM,
) -> None:
    # boot, build and VM runs leave /run/current-system as it was.
    if opts.action != "switch" or not (booted.is_dir() and current.is_dir()):
        return
    reasons = reboot_reasons(booted, current)
    if not reasons:
        return
    joined = ", ".join(reasons)
    warning = paint(PURPLE, "warning")
    print(
        f"{clr_line()}{warning}: reboot recommended for {joined} changes to apply",
        flush=True,
    )
    prompt = f"{clr_line()}{paint(DIM_GREEN, '>')} Reboot now? [y/N] "
    if not _interactive() or not _confirm(prompt):
        return
    if subprocess.run(["systemctl", "reboot", "-i"], check=False).returncode != 0:
        _ = subprocess.run(["sudo", "systemctl", "reboot", "-i"], check=False)
