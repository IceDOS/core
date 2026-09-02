from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from typing import Protocol
from pathlib import Path
from typing import TypeAlias, cast

from .context import BuildEnv
from .genflake import nix_eval_json
from .lockfile import load_lock
from .options import Options
from .util import JSON, warn

# .state file holding remembered custom pins: name -> { rev; repo; }.
UNPINNED_FILE = "unpinned-inputs.json"

# ls-remote/fetch base urls for the forge schemes the pin machinery tracks.
_FORGE_URLS = {
    "github": "https://github.com/{}/{}",
    "gitlab": "https://gitlab.com/{}/{}",
    "sourcehut": "https://git.sr.ht/{}/{}",
}

# Full or abbreviated git sha; revs reach git argv positions unquoted.
_SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")


def _is_sha(rev: str) -> bool:
    return _SHA_RE.match(rev) is not None


def _git_env() -> dict[str, str]:
    # Unauthenticated remotes must fail fast, not prompt on an invisible tty.
    return {
        **os.environ,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "",
        "GIT_SSH_COMMAND": "ssh -oBatchMode=yes",
    }


AskFn: TypeAlias = Callable[[str], bool]
# is x an ancestor-or-equal of y? True/False when decidable, None when git
# could not fetch the commits (offline, forge refusing fetch-by-sha, ...).
AncestryFn: TypeAlias = Callable[[str, str], bool | None]


class _GitLike(Protocol):
    """Structural interface _prune_pass needs, so tests can fake it."""

    def head(self, url: str) -> str: ...

    def ref_head(self, url: str, ref: str) -> str: ...

    def is_ancestor(self, url: str, a: str, b: str) -> bool | None: ...


def _never(_message: str) -> bool:
    return False


class _Git:
    """Cached upstream lookups; git failures degrade to ""/None (unknown)."""

    def __init__(self) -> None:
        self._heads: dict[str, str] = {}
        self._ref_heads: dict[tuple[str, str], str] = {}
        self._ancestry: dict[tuple[str, str, str], bool | None] = {}

    def head(self, url: str) -> str:
        if url not in self._heads:
            try:
                proc = subprocess.run(
                    ["git", "ls-remote", "--", url, "HEAD"],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    env=_git_env(),
                )
            except (OSError, subprocess.TimeoutExpired):
                proc = None
            lines = proc.stdout.split() if proc is not None and proc.returncode == 0 else []
            # Revs reach git argvs and sub-flake urls: never accept non-shas.
            sha = lines[0] if lines else ""
            self._heads[url] = sha if _is_sha(sha) else ""
        return self._heads[url]

    def ref_head(self, url: str, ref: str) -> str:
        # Branch or tag lookup for inputs declared `github:o/r/<ref>`; HEAD
        # would offer a commit from the default branch of a different line.
        if not re.fullmatch(r"[A-Za-z0-9._/-]+", ref):
            return ""
        key = (url, ref)
        if key not in self._ref_heads:
            try:
                proc = subprocess.run(
                    ["git", "ls-remote", "--", url, f"refs/heads/{ref}", f"refs/tags/{ref}"],
                    capture_output=True,
                    text=True,
                    timeout=30,
                    env=_git_env(),
                )
            except (OSError, subprocess.TimeoutExpired):
                proc = None
            resolved: dict[str, str] = {}
            if proc is not None and proc.returncode == 0:
                for line in proc.stdout.splitlines():
                    sha, _, name = line.partition("\t")
                    if name:
                        resolved[name.strip()] = sha.strip()
            # Prefer the branch; for tags take the peeled commit, not the tag object.
            sha = (
                resolved.get(f"refs/heads/{ref}")
                or resolved.get(f"refs/tags/{ref}^{{}}")
                or resolved.get(f"refs/tags/{ref}")
                or ""
            )
            self._ref_heads[key] = sha if _is_sha(sha) else ""
        return self._ref_heads[key]

    def is_ancestor(self, url: str, a: str, b: str) -> bool | None:
        # Revs come from remote JSON / the state file: never let non-shas
        # reach a git argv position.
        if not (_is_sha(a) and _is_sha(b)):
            return None
        if a == b:
            return True
        key = (url, a, b)
        if key not in self._ancestry:
            self._ancestry[key] = self._probe_ancestor(url, a, b)
        return self._ancestry[key]

    @staticmethod
    def _probe_ancestor(url: str, a: str, b: str) -> bool | None:
        tmp = Path(tempfile.mkdtemp(prefix="icedos-ancestry-"))
        try:

            def git(*args: str) -> int:
                try:
                    return subprocess.run(
                        ["git", *args],
                        cwd=tmp,
                        capture_output=True,
                        timeout=120,
                        env=_git_env(),
                    ).returncode
                except subprocess.TimeoutExpired:
                    return -1

            if git("init", "-q") != 0 or git("remote", "add", "origin", "--", url) != 0:
                return None
            # Blobless fetch: only history metadata, never full trees.
            rc = git("fetch", "-q", "--no-tags", "--filter=blob:none", "origin", a, b)
            if rc != 0:
                # Some forges refuse fetch-by-sha; fall back to all branches.
                rc = git("fetch", "-q", "--no-tags", "--filter=blob:none", "origin")
            if rc != 0:
                # ...and partial clones (uploadpack.allowFilter off).
                rc = git("fetch", "-q", "--no-tags", "origin")
            if rc != 0:
                return None
            try:
                probe = subprocess.run(
                    ["git", "merge-base", "--is-ancestor", a, b],
                    cwd=tmp,
                    capture_output=True,
                    timeout=30,
                )
            except subprocess.TimeoutExpired:
                return None
            # 0 = ancestor, 1 = not; anything else (128: bad object, fetch
            # missed the rev, ...) must stay unknown rather than read as False.
            return {0: True, 1: False}.get(probe.returncode)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


def _normalise_entry(value: JSON) -> dict[str, str]:
    # tracked-inputs.json entries are a bare rev or { rev; repo; }; remembered
    # pins additionally carry `checked` (the cache rev last probed against).
    if isinstance(value, str):
        return {"rev": value, "repo": "", "checked": ""}
    if isinstance(value, dict):
        return {
            "rev": str(value.get("rev") or ""),
            "repo": str(value.get("repo") or ""),
            "checked": str(value.get("checked") or ""),
        }
    return {"rev": "", "repo": "", "checked": ""}


def _lock_leaf(lock: dict[str, JSON], name: str) -> dict[str, JSON]:
    # Same node-key lookup as cache-server's tracked-revs.py: exact match, else
    # a "-<name>" suffixed one.
    nodes = lock.get("nodes")
    if not isinstance(nodes, dict):
        return {}
    # Exact key wins; refuse ambiguous suffixes like the nix-side lookup does.
    matches = [name] if name in nodes else [
        k for k in nodes if k.endswith("-" + name)
    ]
    if len(matches) != 1:
        return {}
    key = matches[0]
    node = nodes.get(key)
    if not isinstance(node, dict):
        return {}
    locked = node.get("locked")
    if isinstance(locked, dict) and locked.get("rev"):
        return node  # already the leaf node
    # A rev-less match is the node's sub-flake ROOT (a path node); its inputs
    # map the bare input name, so try that when the full name misses.
    inputs = node.get("inputs")
    if not isinstance(inputs, dict):
        return node
    candidates = [name] if "-" not in name else [name, name.rsplit("-", 1)[-1]]
    for candidate in candidates:
        ref = inputs.get(candidate)
        if isinstance(ref, str):
            nested = nodes.get(ref)
            if isinstance(nested, dict):
                return nested
    return node


def _root_input_names(lock: dict[str, JSON]) -> set[str]:
    # Repo/channel-level names declared on the lock root. Sub-flake ROOTS are
    # root inputs too, but they are legit tracked keys (their leaf hangs off
    # their inputs map), so they are excluded here.
    nodes = lock.get("nodes")
    root_key = lock.get("root")
    node = (
        nodes.get(root_key if isinstance(root_key, str) else "root")
        if isinstance(nodes, dict)
        else None
    )
    inputs = node.get("inputs") if isinstance(node, dict) else None
    if not isinstance(inputs, dict):
        return set()

    def is_subflake_root(key: JSON) -> bool:
        entry = nodes.get(key) if isinstance(key, str) and isinstance(nodes, dict) else None
        original = entry.get("original") if isinstance(entry, dict) else None
        path = original.get("path") if isinstance(original, dict) else None
        return isinstance(path, str) and path.endswith("-subflake")

    return {k for k in inputs if isinstance(k, str) and not is_subflake_root(inputs[k])}


def _leaf_ident(lock: dict[str, JSON], name: str) -> str:
    # Bare "scheme:owner/repo" of the leaf the config actually locks under
    # `name` — the same shape the nix-side repo guard compares against.
    orig = _lock_leaf(lock, name).get("original")
    if not isinstance(orig, dict):
        return ""
    kind = orig.get("type")
    if kind in _FORGE_URLS:
        return f"{kind}:{orig.get('owner')}/{orig.get('repo')}"
    if kind == "git":
        url = orig.get("url", "")
        return url if isinstance(url, str) else ""
    return ""


def _leaf_url(lock: dict[str, JSON], name: str) -> str:
    # https url of that leaf, honoring the self-hosted `host` attribute
    # (mirrors the nix-side fetchTree shape).
    orig = _lock_leaf(lock, name).get("original")
    if not isinstance(orig, dict):
        return ""
    kind = orig.get("type")
    if kind == "git":
        url = str(orig.get("url") or "").removeprefix("git+")
        return url if url.startswith(("https://", "http://", "ssh://", "git://")) else ""
    if kind not in _FORGE_URLS:
        return ""
    owner = str(orig.get("owner") or "").replace("%2F", "/")
    repo = str(orig.get("repo") or "")
    if not owner or not repo:
        return ""
    host = orig.get("host")
    if isinstance(host, str) and host:
        return f"https://{host}/{owner}/{repo}"
    return _FORGE_URLS[kind].format(owner, repo)


def _ident_to_url(ident: str) -> str:
    ident = ident.removeprefix("git+")
    # Scheme allowlist: blocks git's ext:: command-execution transport and any
    # other non-forge scheme smuggled through remote-supplied repo strings.
    if ident.startswith(("https://", "http://", "ssh://", "git://")):
        return ident
    scheme, _, rest = ident.partition(":")
    host_override = ""
    if "?" in rest:
        rest, query = rest.split("?", 1)
        for param in query.split("&"):
            name, _, value = param.partition("=")
            if name == "host":
                host_override = value
    template = _FORGE_URLS.get(scheme)
    if template and "/" in rest:
        owner, repo = rest.split("/", 1)
        # Gitlab subgroups arrive percent-encoded in the owner segment.
        owner = owner.replace("%2F", "/")
        if host_override:
            return f"https://{host_override}/{owner}/{repo}"
        return template.format(owner, repo)
    return ""


def _git_url(entry: dict[str, str], lock: dict[str, JSON], name: str) -> str:
    # The config's own locked leaf is authoritative; the tracked entry's repo is
    # a fallback that must agree when both exist (mirrors the nix repo guard).
    leaf_url = _leaf_url(lock, name)
    if leaf_url:
        if entry["repo"] and entry["repo"] != _leaf_ident(lock, name):
            return ""
        return leaf_url
    return _ident_to_url(entry["repo"])


def decide_pin(
    name: str,
    cache_rev: str,
    saved_rev: str,
    master_rev: str,
    ancestry: AncestryFn,
    ask: AskFn,
) -> tuple[str, str]:
    """Run the four unpin cases for one tracked input.

    Args are the cache-server rev, remembered pin, and master ("" = unknown).
    Returns (action, rev): save/clear/keep/noop/skip.
    """
    if not saved_rev:
        if not cache_rev:
            return "skip", ""
        if not master_rev or cache_rev == master_rev:
            return "noop", ""
        # Cache already at-or-ahead of master: re-pinning would move backward.
        # Diverged/unknown still asks, naming both revs.
        if ancestry(master_rev, cache_rev) is True:
            return "noop", ""
        if ask(f"{name}: pinned to {cache_rev[:12]}, master is at {master_rev[:12]} — re-pin to master?"):
            return "save", master_rev
        return "keep", ""

    # Remembered pin: drop it once the cache-server's rev reaches or passes it.
    if not cache_rev or cache_rev == saved_rev:
        return "clear", ""
    if ancestry(saved_rev, cache_rev) is True:
        return "clear", ""
    # Cache is still behind the custom pin (or ancestry unknown): stay on it
    # unless master moved past the pin too.
    if not master_rev or master_rev == saved_rev:
        return "keep", ""
    if ancestry(saved_rev, master_rev) is False:
        return "keep", ""
    if ask(f"{name}: custom pin {saved_rev[:12]}, master moved to {master_rev[:12]} — re-pin to master?"):
        return "save", master_rev
    return "keep", ""


def _pin_revs(env: BuildEnv, trace: list[str]) -> tuple[dict[str, JSON], dict[str, str]]:
    # One eval for revs and declared refs: genflake's output asserts already
    # force full module discovery, so a revs-only eval would cost the same.
    data = cast(
        "dict[str, JSON]",
        json.loads(nix_eval_json(env, "g: { revs = g.pinRevs; refs = g.pinRefs; }", trace)),
    )
    revs = cast("dict[str, JSON]", data.get("revs") or {})
    refs = cast("dict[str, str]", data.get("refs") or {})
    return revs, refs


def _read_unpinned(path: Path) -> dict[str, JSON]:
    if not path.exists():
        return {}
    try:
        raw = path.read_text()
    except OSError:
        warn(f"warning: unreadable {path}; ignoring remembered custom pins")
        # Unlink so nix's readFile path degrades to "no pins" too, if it can.
        try:
            _ = path.unlink()
        except OSError:
            pass
        return {}
    except UnicodeDecodeError:
        # Non-UTF-8 bytes are corrupt for the nix-side read as well; heal.
        warn(f"warning: unreadable {path}; ignoring remembered custom pins")
        _write_json_atomic(path, {})
        return {}
    try:
        value: JSON = cast(JSON, json.loads(raw))
    except ValueError:
        # Corrupt JSON must heal here: the nix-side read has no tolerance.
        warn(f"warning: unreadable {path}; ignoring remembered custom pins")
        _write_json_atomic(path, {})
        return {}
    if not isinstance(value, dict):
        # Valid JSON but not an object — nix needs an attrset; heal it too.
        _write_json_atomic(path, {})
        return {}
    return value


def _write_json_atomic(path: Path, value: JSON) -> None:
    # write_json truncates in place; a crash mid-write would leave a file that
    # kills every genflake eval, so publish via rename instead.
    _ = path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(value, fh, ensure_ascii=False)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def _drop(saved: dict[str, JSON], name: str, reason: str) -> bool:
    print(f"unpin: {reason}")
    _ = saved.pop(name, None)
    return True


def _prune_pass(
    saved: dict[str, JSON],
    pin_revs: dict[str, JSON],
    lock: dict[str, JSON],
    git: _GitLike,
    skip: set[str],
) -> bool:
    """Case-4 cleanup over remembered pins; returns True when anything changed.

    No ask here: only case 4 is handled, the rest belongs to the main loop.
    """
    changed = False
    for name in sorted(saved):
        if name in skip:
            continue
        entry = _normalise_entry(saved[name])
        if name not in pin_revs:
            changed = _drop(saved, name, f"{name} is no longer cache-tracked; dropping the custom pin") or changed
            continue
        if not entry["rev"]:
            changed = _drop(saved, name, f"{name} has an empty custom pin; dropping it") or changed
            continue
        cache_rev = _normalise_entry(pin_revs[name])["rev"]
        if entry["checked"] == cache_rev:
            continue  # already probed against this cache rev; nothing new to clear
        url = _git_url(entry, lock, name)

        def ancestry(a: str, b: str) -> bool | None:
            return git.is_ancestor(url, a, b) if url else None

        action, _ = decide_pin(name, cache_rev, entry["rev"], "", ancestry, _never)
        if action == "clear":
            reason = (
                f"cache-server reached the custom pin for {name}; dropping it"
                if cache_rev
                else f"{name} is no longer cache-pinned; dropping the custom pin"
            )
            changed = _drop(saved, name, reason) or changed
        elif ancestry(entry["rev"], cache_rev) is False:
            # Definitive "cache behind": stamp the probed cache rev so plain
            # rebuilds skip the git probe until the cache-server moves. An
            # inconclusive probe (offline, no url) must re-probe next time.
            saved[name] = {"rev": entry["rev"], "repo": entry["repo"], "checked": cache_rev}
            changed = True
    return changed


def expire_unpinned(env: BuildEnv, trace: list[str]) -> None:
    """Best-effort case-4 cleanup for plain rebuilds (no --unpin-inputs)."""
    file_path = env.state_dir / UNPINNED_FILE
    saved = _read_unpinned(file_path)
    if not saved:
        return
    try:
        pin_revs, _ = _pin_revs(env, trace)
    except SystemExit:
        warn("warning: could not evaluate the cache pin revs; keeping remembered custom pins")
        return
    if not pin_revs:
        return
    saved_copy = dict(saved)
    if _prune_pass(saved_copy, pin_revs, load_lock(env.state_dir / "flake.lock"), _Git(), set()):
        _write_json_atomic(file_path, cast(JSON, saved_copy))


def unpin_inputs(env: BuildEnv, opts: Options, trace: list[str]) -> None:
    pin_revs, refs = _pin_revs(env, trace)
    if not pin_revs:
        print(
            "error: --unpin-inputs found no cache-pinned inputs. Either\n"
            + "icedos.system.cache.enable or icedos.system.cache.pinInputs is not set,\n"
            + "or there is nothing to diff against yet (first build, or a channel\n"
            + "publish without tracked-inputs.json — both self-heal on the next run).",
            file=sys.stderr,
        )
        raise SystemExit(1)
    lock = load_lock(env.state_dir / "flake.lock")
    root_inputs = _root_input_names(lock)
    if opts.unpin_all:
        # Every cache-tracked module leaf input this config actually locks; the
        # rest is not part of this build, so re-pinning it would change nothing.
        names = [
            n
            for n in sorted(pin_revs)
            # Lock membership, not url derivability: a newer { rev; repo; }
            # entry carries its own repo even for inputs this config never locks.
            if _lock_leaf(lock, n).get("original") and n not in root_inputs
        ]
        if not names:
            warn("warning: no cache-tracked input is locked by this config; nothing to unpin")
        else:
            skipped = [n for n in sorted(pin_revs) if n not in names]
            if skipped:
                warn(
                    "warning: cache-tracked inputs not locked by this config are skipped: "
                    + " ".join(skipped)
                )
    else:
        for name in opts.unpin_inputs:
            if name not in pin_revs:
                tracked = ", ".join(sorted(pin_revs)) or "none"
                print(
                    f"error: '{name}' is not tracked by the cache server (tracked: {tracked})",
                    file=sys.stderr,
                )
                raise SystemExit(1)
            if name in root_inputs:
                print(
                    f"error: '{name}' is a repo-level input, not a module-declared "
                    + "leaf input; the pin machinery does not apply to it",
                    file=sys.stderr,
                )
                raise SystemExit(1)
        names = opts.unpin_inputs

    file_path = env.state_dir / UNPINNED_FILE
    saved = _read_unpinned(file_path)

    git = _Git()
    interactive = sys.stdin.isatty()

    def ask(message: str) -> bool:
        if not interactive:
            warn(f"warning: {message} [y/N] — not a terminal, keeping the current pin")
            return False
        try:
            answer = input(f"{message} [y/N] ")
        except EOFError:
            return False
        return answer.strip().lower() in ("y", "yes")

    changed = _prune_pass(saved, pin_revs, lock, git, set(names))

    for name in names:
        cache = _normalise_entry(pin_revs[name])
        url = _git_url(cache, lock, name)
        saved_rev = _normalise_entry(saved.get(name, ""))["rev"]
        # Case 4 is decidable without the network; run it before the master
        # lookup so an ls-remote failure cannot leave an expired pin in place.
        if saved_rev and (not cache["rev"] or cache["rev"] == saved_rev):
            reason = (
                "custom pin dropped; back on the cache-server's rev"
                if cache["rev"]
                else "is no longer cache-pinned; dropping the custom pin"
            )
            changed = _drop(saved, name, f"{name} {reason}") or changed
            saved_rev = ""
        # The locked leaf's repo is authoritative, so the nix-side repo guard
        # always agrees. Non-forge inputs (git urls) never reach the pin
        # machinery (_cachePin's scheme gate), so skip before any network call.
        leaf = _leaf_ident(lock, name)
        repo = leaf if leaf.partition(":")[0] in _FORGE_URLS else cache["repo"]
        if repo.partition(":")[0] not in _FORGE_URLS:
            warn(
                f"warning: {name}: not a github/gitlab/sourcehut input; "
                + "the pin machinery cannot apply it; skipping"
            )
            continue
        ref = refs.get(name, "")
        master = git.ref_head(url, ref) if (url and ref) else (git.head(url) if url else "")

        def ancestry(a: str, b: str) -> bool | None:
            return git.is_ancestor(url, a, b) if url else None

        if not master:
            ref_note = f" for refs '{ref}'" if ref else ""
            warn(
                f"warning: {name}: no resolvable git url or upstream rev{ref_note} "
                + "(no lock entry, or ls-remote failed); skipping"
            )
            continue
        action, rev = decide_pin(
            name, cache["rev"], saved_rev, master, ancestry, ask,
        )
        if action == "clear":
            changed = _drop(saved, name, f"{name} custom pin dropped; back on the cache-server's rev") or changed
            # The memory is gone — cases 1-2 may still offer a fresh re-pin.
            action, rev = decide_pin(
                name, cache["rev"], "", master, ancestry, ask,
            )
            saved_rev = ""
        if action == "save":
            saved[name] = {"rev": rev, "repo": repo}
            target = f"'{ref}'" if ref else "master"
            print(f"unpin: {name} re-pinned to {target} ({rev[:12]})")
            changed = True
        elif action == "keep":
            if saved_rev:
                print(f"unpin: {name} keeps its custom pin ({saved_rev[:12]})")
            else:
                print(f"unpin: {name} keeps the cache-server's pin ({cache['rev'][:12]})")
        elif action == "skip":
            print(f"unpin: {name} is not cache-pinned; nothing to unpin")
        elif action == "noop":
            print(f"unpin: {name} is already at master; nothing to do")

    if changed:
        _write_json_atomic(file_path, cast(JSON, saved))
        print(f"unpin: wrote {file_path}")
