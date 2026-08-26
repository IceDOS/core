# shellcheck shell=bash
# Helpers for the module repos' `modules/*/update.sh` source-pin updaters.

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

# gh_latest_release OWNER/REPO [TAG_REGEX] — newest non-draft, non-prerelease tag.
# TAG_REGEX scans the release list, for repos with several tag namespaces.
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

# gh_latest_tag OWNER/REPO [TAG_REGEX] — for repos that tag but never release.
# Version-sorted, so it does not depend on the API's tag ordering.
gh_latest_tag() {
  local repo="$1" regex="${2:-.}"

  git ls-remote --tags --refs "https://github.com/$repo.git" 2>/dev/null \
    | sed 's|.*refs/tags/||' \
    | grep -E "$regex" \
    | sort -V \
    | tail -1
}

# gh_release_asset_url OWNER/REPO TAG NAME_REGEX — resolve by pattern: upstreams
# rename assets between releases, and a constructed URL would silently 404.
gh_release_asset_url() {
  local repo="$1" tag="$2" regex="$3"

  gh_api "https://api.github.com/repos/$repo/releases/tags/$tag" \
    | jq -r --arg re "$regex" \
      '[.assets[] | select(.name | test($re))] | first | .browser_download_url // ""'
}

# git_head URL [BRANCH] — HEAD of a branch, for upstreams that never tag.
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

# prefetch_github OWNER REPO REV — SRI for `fetchFromGitHub { rev; hash; }`. Uses the
# tarball, so use prefetch_git for `fetchSubmodules = true`.
prefetch_github() {
  prefetch_unpacked "https://github.com/$1/$2/archive/$3.tar.gz"
}

# prefetch_git_json URL REV [flags...] — full report: hash AND commit date in one
# clone, so an `unstable-<date>` pin needs no rate-limited GitHub API call.
prefetch_git_json() {
  local url="$1" rev="$2"
  shift 2

  nix-prefetch-git --quiet --url "$url" --rev "$rev" "$@" 2>/dev/null
}

# prefetch_git URL REV [flags...] — SRI hash. Matches `fetchgit` and (without
# submodules/LFS) `fetchFromGitHub`; pass --fetch-submodules when it has them.
prefetch_git() {
  prefetch_git_json "$@" | jq -r '.hash // ""'
}

# --- Cargo --------------------------------------------------------------------

# cargo_git_output_hashes LOCKFILE — `cargoLock.outputHashes` JSON: one entry per
# GIT dependency, keyed `<name>-<version>` (crates.io deps must not appear).
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

# require_nonempty LABEL VALUE... — an empty field still evaluates and only fails
# deep in a build, so refuse to write the pin.
require_nonempty() {
  local label="$1"
  shift
  local v
  for v in "$@"; do
    [ -n "$v" ] || error "refusing to write an incomplete $label pin (empty field)"
  done
}

# write_pin FILE — validates the JSON on stdin and writes atomically, keeping the
# caller's field order so pins stay readable and diffs minimal.
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

# No backup/restore helper: updaters resolve rev AND hash before the single `mv`,
# so a half-written pin is never observable.
