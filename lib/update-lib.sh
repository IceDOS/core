# shellcheck shell=bash
#
# Shared helpers for the `modules/*/update.sh` source-pin updaters in the module repos
# (apps, cosmic, hardware, hyprland, tweaks).
#
# Unlike prelude.sh, this is *not* reachable through `icedosLib`: the updaters run as
# standalone scripts in each repo's CI, outside any IceDOS evaluation. They locate core
# on disk instead — CI checks it out beside the repo, and a local IceDOS tree already has
# it as a sibling. Every update.sh opens with the same bootstrap:
#
#   #!/usr/bin/env nix-shell
#   #! nix-shell -i bash -p curl jq nix nix-prefetch-git
#
#   set -euo pipefail
#
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
#   CORE="${ICEDOS_CORE:-$REPO_ROOT/.icedos-core}"
#   [ -d "$CORE" ] || CORE="$REPO_ROOT/../core"
#   [ -f "$CORE/lib/update-lib.sh" ] ||
#     { echo "ERROR: core not found; set ICEDOS_CORE=/path/to/IceDOS/core" >&2; exit 1; }
#   . "$CORE/lib/update-lib.sh"
#
# The nix-shell shebang on the calling script supplies the tools used here: curl, jq,
# nix (nix-prefetch-url), nix-prefetch-git, and git.

# banner TEXT — title plus a rule of the same width, so the two cannot drift apart when a
# package is renamed.
banner() {
  echo "$1"
  printf '%s\n' "${1//?/=}"
}

info() { echo "==> $1"; }
warn() { echo "  WARN: $1" >&2; }
error() {
  echo "ERROR: $1" >&2
  exit 1
}

# --- GitHub API -------------------------------------------------------------
# Unauthenticated is 60 req/h per IP; the workflows pass GITHUB_TOKEN for 5000/h.
gh_api() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sf -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
  else
    curl -sf "$1"
  fi
}

# gh_latest_release OWNER/REPO [TAG_REGEX]
#
# Newest non-draft, non-prerelease tag. With TAG_REGEX, scans the release list and takes
# the first match instead of trusting /releases/latest — needed where a repo publishes
# several tag namespaces (nx-optimizer ships both `manager-*` and `yuzu-*`).
gh_latest_release() {
  local repo="$1" regex="${2:-}"

  if [ -z "$regex" ]; then
    gh_api "https://api.github.com/repos/$repo/releases/latest" \
      | jq -r '.tag_name // ""'
  else
    gh_api "https://api.github.com/repos/$repo/releases?per_page=100" \
      | jq -r --arg re "$regex" \
        '[.[] | select((.draft | not) and (.prerelease | not))
              | select(.tag_name | test($re))] | first | .tag_name // ""'
  fi
}

# gh_latest_tag OWNER/REPO [TAG_REGEX]
#
# For repos that tag but never publish releases (ayatana-ido). Version-sorted so it does
# not depend on the API's tag ordering.
gh_latest_tag() {
  local repo="$1" regex="${2:-.}"

  git ls-remote --tags --refs "https://github.com/$repo.git" 2>/dev/null \
    | sed 's|.*refs/tags/||' \
    | grep -E "$regex" \
    | sort -V \
    | tail -1
}

# gh_release_asset_url OWNER/REPO TAG NAME_REGEX
#
# Resolve an asset by pattern rather than by a constructed filename: upstreams rename
# assets between releases (ReignTweak went from `reigntweak.tar.gz` to a bare
# `reigntweak`), and a constructed URL would silently 404 instead.
gh_release_asset_url() {
  local repo="$1" tag="$2" regex="$3"

  gh_api "https://api.github.com/repos/$repo/releases/tags/$tag" \
    | jq -r --arg re "$regex" \
      '[.assets[] | select(.name | test($re))] | first | .browser_download_url // ""'
}

# git_head URL [BRANCH]
#
# HEAD of a branch, for upstreams that never tag.
git_head() {
  local url="$1" branch="${2:-}"

  if [ -n "$branch" ]; then
    git ls-remote --heads "$url" "$branch" 2>/dev/null | awk '{print $1}' | head -1
  else
    git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1}' | head -1
  fi
}

# --- Hashing ----------------------------------------------------------------

to_sri() {
  local raw="$1"
  [ -z "$raw" ] && return 1
  nix hash to-sri --type sha256 "$raw" 2>/dev/null | grep -v '^warning:'
}

# prefetch_file URL — SRI of the file as-is. Matches `fetchurl` without `unpack`.
prefetch_file() {
  local raw
  raw=$(nix-prefetch-url --type sha256 "$1" 2>/dev/null | tail -1) || return 1
  to_sri "$raw"
}

# prefetch_unpacked URL — SRI of the unpacked tree, root component stripped.
# Matches `fetchzip` / `fetchFromGitLab` / `fetchFromGitHub`.
prefetch_unpacked() {
  local raw
  raw=$(nix-prefetch-url --unpack --type sha256 "$1" 2>/dev/null | tail -1) || return 1
  to_sri "$raw"
}

# prefetch_github OWNER REPO REV — SRI matching `fetchFromGitHub { rev; hash; }`.
# Uses the archive tarball; for `fetchSubmodules = true` use prefetch_git instead, since
# the tarball carries no submodule content.
prefetch_github() {
  prefetch_unpacked "https://github.com/$1/$2/archive/$3.tar.gz"
}

# prefetch_git_json URL REV [extra nix-prefetch-git flags...]
#
# Full nix-prefetch-git report. Worth preferring over prefetch_github for revisions
# tracked by commit: it yields the SRI `hash` *and* the commit `date` in one clone, so an
# updater needs no GitHub API call to build an `unstable-<date>` version string — and
# therefore cannot be defeated by the 60 req/h unauthenticated rate limit.
prefetch_git_json() {
  local url="$1" rev="$2"
  shift 2

  nix-prefetch-git --quiet --url "$url" --rev "$rev" "$@" 2>/dev/null
}

# prefetch_git URL REV [extra nix-prefetch-git flags...] — just the SRI hash.
#
# Matches `fetchgit`, and `fetchFromGitHub` too: for a repo without submodules or LFS the
# git tree and the release tarball hash identically. Pass --fetch-submodules for
# `fetchFromGitHub { fetchSubmodules = true; }`, where the tarball carries no submodules
# and prefetch_github would report the wrong hash.
prefetch_git() {
  prefetch_git_json "$@" | jq -r '.hash // ""'
}

# --- Cargo --------------------------------------------------------------------

# cargo_git_output_hashes LOCKFILE
#
# `rustPlatform.buildRustPackage`'s `cargoLock.outputHashes` needs one entry per git
# dependency, keyed `<name>-<version>`; crates.io dependencies are covered by the lockfile
# itself and must not appear. Cargo records a git dep as
# `source = "git+<url>[?branch=…|?rev=…|?tag=…]#<rev>"`, so each is parsed out and
# prefetched at its locked revision. Prints a JSON object, `{}` when there are none.
cargo_git_output_hashes() {
  local lock="$1"
  local out="{}" name version src url rev hash

  while IFS=$'\t' read -r name version src; do
    [ -n "$src" ] || continue

    rev="${src##*#}"
    url="${src#git+}"
    url="${url%%\#*}"
    url="${url%%\?*}"

    hash=$(prefetch_git "$url" "$rev" || echo "")
    [ -n "$hash" ] || error "could not hash git dependency $name-$version ($url#$rev)"

    out=$(echo "$out" | jq --arg k "$name-$version" --arg v "$hash" '.[$k] = $v')
  done < <(awk '
    /^\[\[package\]\]/                { name=""; version=""; src=""; next }
    /^name = /                        { gsub(/^name = "|"$/, ""); name=$0; next }
    /^version = /                     { gsub(/^version = "|"$/, ""); version=$0; next }
    /^source = "git\+/                { gsub(/^source = "|"$/, ""); src=$0; next }
    /^[[:space:]]*$/                  { if (src != "") print name "\t" version "\t" src
                                        name=""; version=""; src="" }
    END                               { if (src != "") print name "\t" version "\t" src }
  ' "$lock")

  echo "$out"
}

# --- Pin files --------------------------------------------------------------

# read_pin FILE FIELD — jq path (e.g. `.rev`, `.hashes.amd64`), "" when absent.
read_pin() {
  [ -f "$1" ] || {
    echo ""
    return 0
  }
  jq -r "${2} // \"\"" "$1" 2>/dev/null || echo ""
}

# require_nonempty LABEL VALUE...
#
# A pin with an empty field still evaluates, producing a nameless derivation that only
# fails deep in a build. Refuse to write one.
require_nonempty() {
  local label="$1"
  shift
  local v
  for v in "$@"; do
    [ -n "$v" ] || error "refusing to write an incomplete $label pin (empty field)"
  done
}

# write_pin FILE — reads the new JSON on stdin, validates it parses, writes atomically.
# Field order is whatever the caller's `jq -n` emitted (not sorted), so a pin stays
# readable as {version, rev, hash} and its diffs stay minimal.
write_pin() {
  local file="$1" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  jq -e . "$tmp" >/dev/null 2>&1 || {
    rm -f "$tmp"
    error "refusing to write malformed JSON to $file"
  }
  mv "$tmp" "$file"
}

# No pin backup/restore helper is needed: every updater resolves the new revision *and*
# its hash before touching the pin, then writes it with a single `mv`. There is no window
# in which a half-written pin can be observed, so unlike shadps4 — which must write a
# placeholder hash to provoke the mismatch that reveals the real one — nothing here has
# to be rolled back on failure.
