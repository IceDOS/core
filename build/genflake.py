from __future__ import annotations

import json
from collections.abc import Mapping
from typing import cast

from .context import BuildEnv
from .util import JSON, capture, run, write_json, write_text


def nix_eval_json(env: BuildEnv, apply: str, trace: list[str]) -> str:
    cmd = [
        "nix",
        "eval",
        "--json",
        *trace,
        "--file",
        str(env.root / "lib" / "genflake.nix"),
        "--apply",
        apply,
    ]
    return capture(cmd, env={"ICEDOS_STAGE": "genflake"})


def export_search_index(env: BuildEnv, trace: list[str]) -> None:
    env.state_dir.mkdir(parents=True, exist_ok=True)
    cache = env.state_dir / ".cache"
    _ = cache.mkdir(parents=True, exist_ok=True)

    search_docs = nix_eval_json(
        env, "g: { inherit (g) optionsDoc modulesDoc; }", trace
    )
    docs = cast("dict[str, JSON]", json.loads(search_docs))
    for key, filename in (
        ("optionsDoc", "options-doc.json"),
        ("modulesDoc", "modules-doc.json"),
    ):
        value = docs[key]
        if isinstance(value, str):
            write_text(cache / filename, value)
        else:
            write_json(cache / filename, value)
        run(["jsonfmt", str(cache / filename), "-w"], check=True)

    user_config = nix_eval_json(env, "g: g.userConfigRaw", trace)
    write_json(cache / "config.json", cast(JSON, json.loads(user_config)))
    run(["jsonfmt", str(cache / "config.json"), "-w"], check=True)


def generate_flake(
    env: BuildEnv,
    trace: list[str],
    update_env: Mapping[str, str],
    refresh: bool = False,
) -> None:
    cmd = ["nix", "eval", "--raw"]
    if refresh:
        cmd.append("--refresh")
    cmd.extend(
        [
            *trace,
            "--file",
            str(env.root / "lib" / "genflake.nix"),
            "flakeFinal",
        ]
    )
    stdout = capture(cmd, env={"ICEDOS_STAGE": "genflake", **update_env})
    write_text(env.state_dir / "flake.nix", stdout.rstrip("\n") + "\n")
    run(["nixfmt", str(env.state_dir / "flake.nix")], check=True)
