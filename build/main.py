from __future__ import annotations

import os
import sys

from .context import from_environment
from .genflake import export_search_index, generate_flake
from .options import parse_args
from .runner import build
from .update import maybe_re_exec_update_core, prepare_lock, refresh_config_root_paths


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    opts, previous_arguments = parse_args(args)

    os.environ["NIXPKGS_ALLOW_UNFREE"] = "1"
    os.environ["NIX_CONFIG"] = (
        "experimental-features = flakes nix-command pipe-operators"
    )
    if opts.logs:
        os.environ["ICEDOS_LOGGING"] = "1"

    env = from_environment()
    trace = opts.trace

    if opts.export_search_index:
        export_search_index(env, trace)
        return 0

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
