from __future__ import annotations

import sys

# SGR parameters named after the lib/prelude.sh colour variables they mirror.
GREEN = "1;32"
PURPLE = "1;35"
RED = "1;31"
YELLOW = "1;33"
DIM_GREEN = "0;32"


# Like the prelude, keyed off stdout even for messages that go to stderr.
def styled() -> bool:
    return sys.stdout.isatty()


def paint(sgr: str, text: str) -> str:
    return f"\033[{sgr}m{text}\033[0m" if styled() else text


# Erases the progress line a child process may have left (the prelude's CLR_LINE).
def clr_line() -> str:
    return "\033[2K\r" if styled() else ""


def log_step(message: str) -> None:
    print(f"{paint(DIM_GREEN, '>')} {message}", flush=True)


def log_ok(message: str) -> None:
    print(f"{paint(GREEN, '✓')} {message}", flush=True)


def log_warn(message: str) -> None:
    print(f"{paint(YELLOW, '⚠')} {message}", file=sys.stderr, flush=True)
