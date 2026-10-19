from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import NoReturn

from .term import log_warn


@dataclass
class Options:
    action: str = "switch"
    run_vm: bool = False
    genflake_only: bool = False
    dry: bool = False
    lock_only: bool = False
    keep_flake: bool = False
    export_search_index: bool = False
    update_all: bool = False
    update_hooks: bool = False
    update_core: bool = False
    update_core_only: bool = False
    update_repos: bool = False
    update_repos_inputs: bool = False
    state_inputs: list[str] = field(default_factory=list)
    update_except: list[str] = field(default_factory=list)
    freeze_inputs: list[str] = field(default_factory=list)
    cache_pinned: list[str] = field(default_factory=list)
    repos_select: list[str] = field(default_factory=list)
    github_token: str | None = None
    github_token_path: str | None = None
    nh_build_args: list[str] = field(default_factory=list)
    global_build_args: list[str] = field(default_factory=list)
    logs: bool = False

    @property
    def trace(self) -> list[str]:
        return ["--show-trace"] if self.logs else []


# Single literals, not adjacent ones: implicit concatenation is disallowed.
_ERR_REPOS_SELECT = """\
error: --update-repos-select requires a space-separated list of repo urls
  usage: --update-repos-select "github:icedos/apps github:icedos/gaming\""""

_ERR_STATE_INPUTS = """\
error: --update-state-inputs requires a space-separated list of input names
  usage: --update-state-inputs "nixpkgs home-manager\""""

_ERR_UPDATE_EXCEPT = """\
error: --update-except requires a space-separated list of input names
  usage: --update-except "nixpkgs home-manager\""""


def _die(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def _take_list(flag: str, value: str) -> list[str]:
    parsed = value.split()
    if not parsed:
        _die(f"error: {flag} received an empty list")
    return parsed


# Shared with the shim, which `cat`s the same file for `icedos rebuild --help`.
def usage() -> str:
    return (Path(__file__).parent / "usage.txt").read_text()


def parse_args(argv: list[str]) -> tuple[Options, list[str]]:
    opts = Options()
    previous_arguments = list(argv)

    i = 0
    while i < len(argv):
        arg = argv[i]

        if arg == "--boot":
            opts.action = "boot"
            i += 1
        elif arg == "--build":
            opts.action = "build"
            i += 1
        elif arg == "--build-vm":
            opts.action = "build-vm"
            i += 1
        elif arg == "--run-vm":
            opts.action = "build-vm"
            opts.run_vm = True
            i += 1
        elif arg == "--genflake-only":
            opts.genflake_only = True
            i += 1
        elif arg == "--keep-flake":
            opts.keep_flake = True
            i += 1
        elif arg == "--lock-only":
            opts.lock_only = True
            opts.genflake_only = True
            i += 1
        elif arg == "--export-search-index":
            opts.export_search_index = True
            i += 1
        elif arg == "--update":
            opts.update_all = True
            opts.update_core = True
            opts.update_repos = True
            opts.update_repos_inputs = True
            i += 1
        elif arg == "--update-core":
            opts.update_core = True
            i += 1
        elif arg == "--update-core-only":
            opts.update_core_only = True
            i += 1
        elif arg == "--update-repos":
            opts.update_repos = True
            opts.update_repos_inputs = True
            i += 1
        elif arg == "--update-repos-only":
            opts.update_repos = True
            i += 1
        elif arg == "--update-repo-inputs-only":
            opts.update_repos_inputs = True
            i += 1
        elif arg == "--update-repos-select":
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                _die(_ERR_REPOS_SELECT)
            opts.repos_select.extend(_take_list(arg, argv[i + 1]))
            i += 2
        elif arg == "--update-state-inputs":
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                _die(_ERR_STATE_INPUTS)
            opts.state_inputs.extend(_take_list(arg, argv[i + 1]))
            i += 2
        elif arg == "--update-except":
            if i + 1 >= len(argv) or argv[i + 1].startswith("--"):
                _die(_ERR_UPDATE_EXCEPT)
            opts.update_except.extend(_take_list(arg, argv[i + 1]))
            i += 2
        elif arg == "--ask":
            opts.nh_build_args.append("-a")
            i += 1
        elif arg == "--builder":
            if i + 1 >= len(argv):
                _die("error: --builder requires a host")
            opts.nh_build_args.extend(["--build-host", argv[i + 1]])
            i += 2
        elif arg == "--target":
            if i + 1 >= len(argv):
                _die("error: --target requires a host")
            opts.nh_build_args.extend(["--target-host", argv[i + 1]])
            i += 2
        elif arg == "--nh-args":
            i += 1
            while i < len(argv) and argv[i] != "--build-args":
                opts.nh_build_args.append(argv[i])
                i += 1
        elif arg == "--build-args":
            opts.global_build_args = argv[i + 1 :]
            break
        elif arg == "--github-token":
            if i + 1 >= len(argv):
                _die("error: --github-token requires a token")
            opts.github_token = argv[i + 1]
            i += 2
        elif arg == "--github-token-path":
            if i + 1 >= len(argv):
                _die("error: --github-token-path requires a path")
            opts.github_token_path = argv[i + 1]
            i += 2
        elif arg == "--logs":
            opts.logs = True
            i += 1
        elif arg in ("--dry", "--dry-run", "-n"):
            opts.dry = True
            opts.genflake_only = True
            i += 1
        elif arg == "--update-hooks":
            opts.update_hooks = True
            i += 1
        elif arg in ("--help", "-h"):
            print(usage(), end="")
            raise SystemExit(0)
        else:
            _die(f"Unknown arg: {arg}")

    if opts.keep_flake and (opts.dry or not opts.genflake_only or opts.lock_only):
        _die("error: --keep-flake only applies with --genflake-only")
    if opts.lock_only and opts.dry:
        _die("error: --dry and --lock-only cannot be combined")
    if opts.lock_only and opts.update_hooks:
        _die("error: --lock-only and --update-hooks cannot be combined")

    if opts.dry and opts.update_hooks:
        log_warn("--update-hooks ignored under --dry")
        opts.update_hooks = False

    if opts.lock_only:
        updating = (
            opts.update_all
            or opts.update_core
            or opts.update_core_only
            or opts.update_repos
            or opts.update_repos_inputs
            or bool(opts.repos_select)
            or bool(opts.state_inputs)
        )
        if not updating:
            _die("error: --lock-only needs an update flag, e.g. icedos rebuild --update --lock-only")
        if opts.action != "switch" or opts.nh_build_args or opts.global_build_args:
            _die(
                "error: --lock-only does not build; drop "
                "--boot/--build/--build-vm/--run-vm/--ask/--builder/--target/--nh-args/--build-args"
            )

    if opts.update_except and not (opts.update_all or opts.update_core):
        _die("error: --update-except only applies with --update or --update-core")
    overlap = set(opts.update_except) & set(opts.state_inputs)
    if overlap:
        _die(f"error: '{sorted(overlap)[0]}' is both selected and excluded")

    return opts, previous_arguments
