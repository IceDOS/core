from __future__ import annotations

import sys
from dataclasses import dataclass, field
from typing import NoReturn


@dataclass
class Options:
    action: str = "switch"
    run_vm: bool = False
    genflake_only: bool = False
    export_search_index: bool = False
    update_all: bool = False
    update_core: bool = False
    update_core_only: bool = False
    update_repos: bool = False
    update_repos_inputs: bool = False
    state_inputs: list[str] = field(default_factory=list)
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


def _die(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def _take_list(flag: str, value: str) -> list[str]:
    parsed = value.split()
    if not parsed:
        _die(f"error: {flag} received an empty list")
    return parsed


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
        else:
            _die(f"Unknown arg: {arg}")

    return opts, previous_arguments
