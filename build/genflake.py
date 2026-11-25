from __future__ import annotations

import json
import os
from collections.abc import Mapping
from dataclasses import dataclass
from typing import NoReturn, cast

from .context import BuildEnv
from .util import JSON, capture, run, warn, write_json, write_text


def _nix_eval_json(env: BuildEnv, apply: str, trace: list[str]) -> str:
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


def _nix_eval_attr_json(env: BuildEnv, attr: str, trace: list[str]) -> JSON:
    cmd = [
        "nix",
        "eval",
        "--json",
        *trace,
        "--file",
        str(env.root / "lib" / "genflake.nix"),
        attr,
    ]
    return cast(JSON, json.loads(capture(cmd, env={"ICEDOS_STAGE": "genflake"})))


def _invalid_attr(attr: str, data: JSON) -> NoReturn:
    warn(f"error: genflake's {attr} is malformed: {data!r}")
    raise SystemExit(1)


@dataclass(frozen=True)
class CachePin:
    """One cache-pinned input.

    `url` is the rev-less base (for `<url>/<cacheRev>` date lookups), `latestUrl`
    the branch/ref a re-unpin resolves (nixpkgs stays on its channel, a leaf keeps
    the author's ref).
    """

    url: str
    latest_url: str
    rev: str
    last_modified: int | None


def cache_unpin_info(env: BuildEnv, trace: list[str]) -> dict[str, CachePin]:
    """Every cache-pinned input pinned by the cache-server channel.

    Forces module resolution, so eval it once per rebuild, not per name.
    """
    data = _nix_eval_attr_json(env, "cacheUnpinInfo", trace)
    if not isinstance(data, dict):
        _invalid_attr("cacheUnpinInfo", data)
    pins: dict[str, CachePin] = {}
    for name, entry in data.items():
        url = entry.get("url") if isinstance(entry, dict) else None
        latest = entry.get("latestUrl") if isinstance(entry, dict) else None
        rev = entry.get("cacheRev") if isinstance(entry, dict) else None
        mtime = entry.get("cacheLastModified") if isinstance(entry, dict) else None
        if not isinstance(name, str) or not isinstance(url, str) or not url:
            _invalid_attr("cacheUnpinInfo", data)
        if not isinstance(latest, str) or not latest:
            _invalid_attr("cacheUnpinInfo", data)
        if not isinstance(rev, str) or not rev:
            _invalid_attr("cacheUnpinInfo", data)
        if mtime is not None and (isinstance(mtime, bool) or not isinstance(mtime, int)):
            _invalid_attr("cacheUnpinInfo", data)
        pins[name] = CachePin(
            url=url, latest_url=latest, rev=rev, last_modified=mtime
        )
    return pins


def export_search_index(env: BuildEnv, trace: list[str]) -> None:
    env.state_dir.mkdir(parents=True, exist_ok=True)
    cache = env.state_dir / ".cache"
    _ = cache.mkdir(parents=True, exist_ok=True)

    search_docs = _nix_eval_json(
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

    user_config = _nix_eval_json(env, "g: g.userConfigRaw", trace)
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
    target = env.state_dir / "flake.nix"
    target.parent.mkdir(parents=True, exist_ok=True)
    # Keep the .nix suffix: nixfmt deprecates formatting non-.nix files.
    tmp_path = target.parent / "flake.icedos-tmp.nix"
    _ = tmp_path.write_text(stdout.rstrip("\n") + "\n")
    run(["nixfmt", str(tmp_path)], check=True)
    os.replace(tmp_path, target)


def cache_pinned_inputs(env: BuildEnv, trace: list[str]) -> list[str]:
    cmd = [
        "nix",
        "eval",
        "--json",
        *trace,
        "--file",
        str(env.root / "lib" / "genflake.nix"),
        "cachePinnedInputs",
    ]
    stdout = capture(cmd, env={"ICEDOS_STAGE": "genflake"})
    try:
        data = json.loads(stdout)
        return [str(x) for x in data] if isinstance(data, list) else []
    except ValueError:
        return []
