from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from .context import from_environment
from .genflake import export_search_index, generate_flake
from .options import Options, parse_args
from .runner import build
from .update import maybe_re_exec_update_core, prepare_lock, refresh_config_root_paths
from .util import warn

# Lowest priority; overridable by a literal (--github-token / ICEDOS_GITHUB_TOKEN)
# or a token file (--github-token-path / ICEDOS_GITHUB_TOKEN_PATH).
DEFAULT_TOKEN_PATH = "/etc/icedos-github-token"

# Everything nix needs that carries no credential, so it can be set before the
# token is resolved (see the --export-search-index early return in main).
BASE_NIX_CONFIG = "experimental-features = flakes nix-command pipe-operators"


def _token_file_path(opts: Options) -> Path:
    return Path(
        opts.github_token_path
        or os.environ.get("ICEDOS_GITHUB_TOKEN_PATH")
        or DEFAULT_TOKEN_PATH
    )


# NIX_CONFIG is nix.conf content (line-based), so the token needs its own line.
def _nix_config(opts: Options) -> str:
    config = BASE_NIX_CONFIG
    token = _resolve_token(opts)
    if token:
        config += f"\naccess-tokens = github.com={token}"
    return config


# Literal token (arg, then ICEDOS_GITHUB_TOKEN env) beats any file; the file path
# falls back from --github-token-path through ICEDOS_GITHUB_TOKEN_PATH to default.
def _resolve_token(opts: Options) -> str:
    literal = (opts.github_token or "").strip()
    if literal:
        return literal
    literal = (os.environ.get("ICEDOS_GITHUB_TOKEN") or "").strip()
    if literal:
        return literal
    return _read_token_file(_token_file_path(opts))


def _read_token_file(path: Path) -> str:
    if not path.exists():
        return ""
    try:
        return path.read_text().strip()
    except (OSError, ValueError):
        # ValueError covers UnicodeDecodeError on a file that is not UTF-8 text.
        pass

    # Root-owned file: try passwordless sudo, then a prompt when on a terminal.
    token = _sudo_read(path)
    if token is None:
        warn(f"warning: cannot read {path}; skipping GitHub access token")
        return ""
    # Stripped here too: `cat` keeps the trailing newline, and a stray \r would
    # otherwise ride along into the access-tokens line and fail auth silently.
    return token.strip()


def _sudo_read(path: Path) -> str | None:
    # (argv, quiet). The passwordless probe swallows sudo's failure noise; the
    # interactive attempt must not, or its prompt would be invisible.
    attempts: list[tuple[list[str], bool]] = [(["sudo", "-n", "cat", str(path)], True)]
    if sys.stdin.isatty():
        # sudo prompts on /dev/tty, so the password question shows even with piped stdout.
        attempts.append((["sudo", "cat", str(path)], False))
    for cmd, quiet in attempts:
        proc = subprocess.run(
            cmd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL if quiet else None,
            text=True,
        )
        if proc.returncode == 0:
            return proc.stdout or ""
    return None


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    opts, previous_arguments = parse_args(args)

    os.environ["NIXPKGS_ALLOW_UNFREE"] = "1"
    os.environ["NIX_CONFIG"] = BASE_NIX_CONFIG
    if opts.logs:
        os.environ["ICEDOS_LOGGING"] = "1"
    if opts.github_ssh:
        # Read by the genflake eval, baked into the generated flake as
        # githubViaSsh; the build stage consumes that value, so sites agree.
        os.environ["ICEDOS_GITHUB_SSH"] = "1"

    env = from_environment()
    trace = opts.trace

    # Defer token resolution past this return: a local genflake.nix eval needs no
    # credential, and a root-owned token file can stop on a sudo password prompt.
    if opts.export_search_index:
        export_search_index(env, trace)
        return 0

    os.environ["NIX_CONFIG"] = _nix_config(opts)

    refresh_config_root_paths(env, opts)
    maybe_re_exec_update_core(env, opts, previous_arguments)

    generate_flake(
        env,
        trace,
        {
            "ICEDOS_UPDATE": "1" if opts.update_repos else "",
            "ICEDOS_UPDATE_MODULE_INPUTS": "1" if opts.update_repos_inputs else "",
            "ICEDOS_UPDATE_REPOS_SELECT": " ".join(opts.repos_select),
        },
        refresh=bool(opts.update_repos or opts.repos_select),
    )

    prepare_lock(env, opts, trace)

    if opts.genflake_only:
        return 0

    build(env, opts)
    return 0
