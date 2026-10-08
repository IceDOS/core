from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from .context import BuildEnv, RebuildContext, from_environment, load_rebuild_context
from .genflake import export_search_index, generate_flake
from .hooks import run_hooks
from .options import Options, parse_args
from .reboot import offer_reboot
from .runner import build
from .snapshot import current_generation, record_rebuild
from .term import RED, clr_line, log_ok, log_step, log_warn, paint
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


def _exit_code(exc: SystemExit) -> int:
    if exc.code is None:
        return 0
    return exc.code if isinstance(exc.code, int) else 1


def _run_update_hooks(env: BuildEnv, ctx: RebuildContext | None) -> int:
    if ctx is None:
        log_warn("--update-hooks: no rebuild hooks available here; nothing to run")
        return 0
    run_hooks(ctx, "preUpdate", cwd=env.state_dir, hooks_only=True)
    run_hooks(ctx, "postUpdate", cwd=env.state_dir, hooks_only=True)
    return 0


def _rebuild(
    env: BuildEnv,
    opts: Options,
    ctx: RebuildContext | None,
    previous_arguments: list[str],
) -> int:
    trace = opts.trace
    os.environ["NIX_CONFIG"] = _nix_config(opts)

    refresh_config_root_paths(env, opts)
    # Before any hook, so after an update the new core runs every phase below.
    maybe_re_exec_update_core(env, opts, previous_arguments)

    # Hooks and the post-build phases need the shim's context and a real build.
    wrapped = None if opts.genflake_only else ctx
    if opts.dry:
        log_step("dry run — generating flake...")
    if wrapped is not None:
        run_hooks(wrapped, "preRebuild", cwd=env.state_dir)
        if opts.update_all:
            run_hooks(wrapped, "preUpdate", cwd=env.state_dir)

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
        if opts.dry:
            log_ok(
                "dry run — flake generated and inputs locked (module eval not checked)"
            )
        return 0

    before = current_generation() if wrapped is not None else None
    build(env, opts)

    if wrapped is None:
        return 0
    if opts.update_all:
        run_hooks(wrapped, "postUpdate", cwd=env.state_dir)
    try:
        record_rebuild(env, opts, wrapped, previous_generation=before)
    except KeyboardInterrupt:
        print("interrupted after build", file=sys.stderr)
        raise SystemExit(130) from None
    run_hooks(wrapped, "postRebuild", cwd=env.state_dir)
    offer_reboot(opts)
    return 0


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    opts, previous_arguments = parse_args(args)
    ctx = load_rebuild_context(os.environ)

    os.environ["NIXPKGS_ALLOW_UNFREE"] = "1"
    os.environ["NIX_CONFIG"] = BASE_NIX_CONFIG
    if opts.logs:
        os.environ["ICEDOS_LOGGING"] = "1"

    env = from_environment()

    # Defer token resolution past this return: a local genflake.nix eval needs no
    # credential, and a root-owned token file can stop on a sudo password prompt.
    if opts.export_search_index:
        export_search_index(env, opts.trace)
        return 0

    # --update-hooks needs no token, update or build.
    if opts.update_hooks:
        return _run_update_hooks(env, ctx)

    try:
        return _rebuild(env, opts, ctx, previous_arguments)
    except SystemExit as exc:
        code = _exit_code(exc)
        # 130 already got its own interrupt report.
        if ctx is not None and not opts.dry and code not in (0, 130):
            print(
                f"{clr_line()}{paint(RED, 'error')}: build failed with exit code {code}"
            )
        raise
    except Exception:
        if ctx is not None and not opts.dry:
            print(f"{clr_line()}{paint(RED, 'error')}: build failed with exit code 1")
        raise
