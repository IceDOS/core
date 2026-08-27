#!/usr/bin/env bash

export NIXPKGS_ALLOW_UNFREE=1

FLAKE="flake.nix"

cd "$(dirname "$(readlink -f "$0")")"

action="switch"
globalBuildArgs=()
nhBuildArgs=()

set -e
set -o pipefail

# INPUTS_PREFIX from flake (via icedosBuild wrapper), fallback to "icedos"
inputs_prefix="${ICEDOS_INPUTS_PREFIX:-icedos}"

previous_arguments=("$@")
state_inputs=()        # Generic input names from --update-state-inputs (state flake)
repos_select=()        # Repo urls from --update-repos-select

while [[ $# -gt 0 ]]; do
  case $1 in
    --boot)
      action="boot"
      shift
      ;;
    --build)
      action="build"
      shift
      ;;
    --build-vm)
      action="build-vm"
      shift
      ;;
    --run-vm)
      action="build-vm"
      run_vm=1
      shift
      ;;
    --genflake-only)
      genflake_only=1
      shift
      ;;
    --export-search-index)
      export_search_index=1
      shift
      ;;
    --update)
      update_all="1"
      update_core="1"
      update_repos="1"
      update_repos_inputs="1"
      shift
      ;;
    --update-core)
      update_core="1"
      shift
      ;;
    --update-core-only)
      update_core_only="1"
      shift
      ;;
    --update-repos)
      update_repos="1"
      update_repos_inputs="1"
      shift
      ;;
    --update-repos-only)
      update_repos="1"
      shift
      ;;
    --update-repo-inputs-only)
      update_repos_inputs="1"
      shift
      ;;
    --update-repos-select)
      # Repo urls to update.
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "error: --update-repos-select requires a space-separated list of repo urls" >&2
        echo "  usage: --update-repos-select \"github:icedos/apps github:icedos/gaming\"" >&2
        exit 1
      fi
      IFS=' ' read -ra _parsed <<< "$2"
      if [[ ${#_parsed[@]} -eq 0 ]]; then
        echo "error: --update-repos-select received an empty repo list" >&2
        exit 1
      fi
      repos_select+=("${_parsed[@]}")
      shift 2
      ;;
    --update-state-inputs)
      # Space-separated list of inputs to update in the state flake.
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "error: --update-state-inputs requires a space-separated list of input names" >&2
        echo "  usage: --update-state-inputs \"nixpkgs home-manager\"" >&2
        exit 1
      fi
      IFS=' ' read -ra _parsed <<< "$2"
      if [[ ${#_parsed[@]} -eq 0 ]]; then
        echo "error: --update-state-inputs received an empty input list" >&2
        exit 1
      fi
      state_inputs+=("${_parsed[@]}")
      shift 2
      ;;
    --ask)
      nhBuildArgs+=("-a")
      shift
      ;;
    --builder)
      nhBuildArgs+=("--build-host")
      nhBuildArgs+=("$2")
      shift 2
      ;;
    --target)
      nhBuildArgs+=("--target-host")
      nhBuildArgs+=("$2")
      shift 2
      ;;
    --nh-args)
      shift
      while [[ $# -gt 0 && "$1" != "--build-args" ]]; do
        nhBuildArgs+=("$1")
        shift
      done
      ;;
    --build-args)
      shift
      globalBuildArgs=("$@")
      break
      ;;
    --logs)
      export ICEDOS_LOGGING=1
      trace="--show-trace"
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

export NIX_CONFIG="experimental-features = flakes nix-command pipe-operators"

# Search/validate index for the CLI and webui. Evaluates genflake.nix directly —
# no generated flake, no lock refresh, no build — and exits.
if [ "$export_search_index" == "1" ]; then
  (
    cd "$ICEDOS_STATE_DIR"
    mkdir -p .cache
    # One eval for both docs; per-doc evals would redo the whole module resolution.
    search_docs=$(ICEDOS_STAGE="genflake" nix eval --json $trace \
      --file "$ICEDOS_ROOT/lib/genflake.nix" \
      --apply 'g: { inherit (g) optionsDoc modulesDoc; }')

    jq -r '.optionsDoc' <<< "$search_docs" > .cache/options-doc.json
    jq -r '.modulesDoc' <<< "$search_docs" > .cache/modules-doc.json
    jsonfmt .cache/options-doc.json -w
    jsonfmt .cache/modules-doc.json -w

    # The merged config set, so the webui editor can tell which keys the user set
    # and recover submodule lists the options doc doesn't expand.
    user_config=$(ICEDOS_STAGE="genflake" nix eval --json $trace \
      --file "$ICEDOS_ROOT/lib/genflake.nix" \
      --apply 'g: g.userConfigRaw')
    jq '.' <<< "$user_config" > .cache/config.json
    jsonfmt .cache/config.json -w
  )

  exit 0
fi

# Refresh `path:` inputs so a local-core override lands without --update-core;
# github/git stay pinned. Skipped under --update-core (full refresh below).
if [ "$update_core" != "1" ] \
   && [ -n "$ICEDOS_CONFIG_ROOT" ] \
   && [ -f "$ICEDOS_CONFIG_ROOT/flake.lock" ]; then
  (
    set -e
    cd "$ICEDOS_CONFIG_ROOT"
    for input in $(jq -r '.nodes | to_entries[] | select(.value.locked.type == "path") | .key' flake.lock 2>/dev/null); do
      nix flake update "$input" 2>/dev/null || true
    done
  )
fi

# Config-flake update routing: --update-core refreshes everything; specific flags
# target individual inputs. All paths re-execute the build with a fresh lock.
if [[ -n "$update_core$update_core_only" && -z "$skip_update_core" && -n "$ICEDOS_CONFIG_ROOT" ]]; then
  cd "$ICEDOS_CONFIG_ROOT"
  if [ "$update_core" == "1" ]; then
    nix flake update --refresh
  else
    nix flake update icedos --refresh
  fi
  exec env skip_update_core=1 nix run path:. -- "${previous_arguments[@]}"
  exit 0
fi

if [ "$update_repos" == "1" ] || [ ${#repos_select[@]} -gt 0 ]; then
  refresh="--refresh"
fi

# Separate bake-suppression flags: a baked rev would pin the very input the
# running update flag is about to bump. --update sets both.
update_flag="$update_repos"
update_module_inputs_flag="$update_repos_inputs"
update_repos_select_flag="${repos_select[*]}"

# Captured first, written second, so a failed eval leaves the previous
# `.state/flake.nix` intact instead of truncating it.
flake_final=$(ICEDOS_UPDATE="$update_flag" ICEDOS_UPDATE_MODULE_INPUTS="$update_module_inputs_flag" \
  ICEDOS_UPDATE_REPOS_SELECT="$update_repos_select_flag" \
  ICEDOS_STAGE="genflake" nix eval --raw $refresh $trace \
  --file "$ICEDOS_ROOT/lib/genflake.nix" flakeFinal)
printf '%s\n' "$flake_final" >"$ICEDOS_STATE_DIR/$FLAKE"
nixfmt "$ICEDOS_STATE_DIR/$FLAKE"
# Sub-flakes exist only as store paths in the generated flake's root inputs, so
# `flake.lock` is the single source of truth for which inputs belong to which.

# Lock in a DETACHED copy: nix treats `.state` as a git flake, and a git flake
# refuses to lock an untracked `path:` input. Only flake.lock is copied back.
lock_dir="$(mktemp -d -t icedos-lock-XXXXXXX-0)"
trap 'rm -rf "$lock_dir" 2>/dev/null || true' EXIT
rsync -a --exclude=".cache" "$ICEDOS_STATE_DIR/" "$lock_dir/"

sync_lock() {
  if [ -f "$lock_dir/flake.lock" ]; then
    cp "$lock_dir/flake.lock" "$ICEDOS_STATE_DIR/flake.lock"
  else
    echo "warning: no flake.lock in detached lock dir — nothing to sync" >&2
  fi
}

# Sub-flake roots: `path:` root inputs whose store path ends `-<name>-subflake`.
# Keys come from `nodes.root.inputs` — nix suffixes colliding node names.
subflakes_from_lock() {
  jq -r '
    . as $doc | $doc.nodes.root.inputs | to_entries[]
    | .key as $k | .value as $key
    | select(($key | type) == "string")
    | select($doc.nodes[$key].locked.type == "path")
    | select($doc.nodes[$key].locked.path | startswith("/nix/store/"))
    | select($doc.nodes[$key].locked.path | endswith("-" + $k + "-subflake"))
    | $k
  ' "$1" 2>/dev/null
}

# Captured before the lock step creates one: prefetch needs a lock, but a first
# build is exactly when the parallel prefetch is worth it.
first_lock=0
[ -f "$lock_dir/flake.lock" ] || first_lock=1

(
  set -e
  cd "$lock_dir"

  # A changed sub-flake has a new store path, so this re-locks that root alone —
  # `nix flake update <sub>` would re-resolve its whole subtree to latest.
  nix flake lock

  # Store warming only; needs the lock above.
  if [ "$first_lock" == "1" ] || [ -n "$update_core$update_repos$update_repos_inputs" ] || [ ${#state_inputs[@]} -gt 0 ] || [ ${#repos_select[@]} -gt 0 ]; then
    nix flake prefetch-inputs
  fi

  # Local `path:` roots (overrideUrl checkouts) refresh every build; github/git
  # stay pinned. Store paths are skipped — updating one unpins its whole subtree.
  for input in $(jq -r '. as $doc | $doc.nodes.root.inputs | to_entries[] | .key as $k | .value as $key | select(($key | type) == "string") | select($doc.nodes[$key].locked.type == "path") | $k' flake.lock 2>/dev/null); do
    locked_path=$(jq -r --arg k "$input" '.nodes.root.inputs[$k] as $key | select(($key | type) == "string") | .nodes[$key].locked.path // ""' flake.lock)
    case "$locked_path" in
      /nix/store/*) continue ;;
    esac
    nix flake update "$input" 2>/dev/null || true
  done

  # Same for local `path:` inputs NESTED in a sub-flake: a plain lock keeps their
  # stale narHash (the url string never changed), so refresh them explicitly.
  for sub in $(subflakes_from_lock flake.lock); do
    for input in $(jq -r --arg sub "$sub" '
      . as $doc
      | $doc.nodes.root.inputs[$sub] as $key
      | select(($key | type) == "string")
      | $doc.nodes[$key].inputs | to_entries[]
      | select(.value | type == "string")
      | .key as $in | .value as $lk
      | select($doc.nodes[$lk].locked.type == "path")
      | select(($doc.nodes[$lk].locked.path | startswith("/nix/store/")) | not)
      | $in
    ' flake.lock 2>/dev/null); do
      nix flake update "$sub/$input" 2>/dev/null || true
    done
  done

  [ "$update_core" == "1" ] && nix flake update icedos-core --refresh 2>/dev/null || true
)

if [ "$update_all" == "1" ]; then
  (
    set -e
    cd "$lock_dir"
    nix flake update --refresh
  )
elif [ "$update_repos_inputs" == "1" ]; then
  (
    set -e
    cd "$lock_dir"
    # Only module inputs nested in their sub-flake; repo pins stay untouched
    # (that is --update-repos). Only STRING entries are real nodes — arrays are
    # `follows`, and bumping one unpins nixpkgs.
    mapfile -t subflakes < <(subflakes_from_lock flake.lock)
    for sub in "${subflakes[@]}"; do
      for input in $(jq -r --arg sub "$sub" '.nodes.root.inputs[$sub] as $key | select(($key | type) == "string") | .nodes[$key].inputs | to_entries[] | select(.value | type == "string") | .key' flake.lock 2>/dev/null); do
        nix flake update "$sub/$input" --refresh 2>/dev/null || true
      done
    done
  )
fi

# Update specific inputs in the state flake.lock.
# Skips icedos-prefixed inputs — controlled by genflake.
if [[ ${#state_inputs[@]} -gt 0 ]]; then
  (
    set -e
    cd "$lock_dir"
    # Filter out pinned repos and validate all inputs upfront.
    valid_inputs=()
    for input in "${state_inputs[@]}"; do
      # All icedos-* inputs are managed by genflake (repos, sub-flakes, overlays).
      # Skip them unconditionally — use --update-repos / --update-repo-inputs-only.
      if [[ "$input" == "${inputs_prefix}"-* ]]; then
        echo "warning: skipping '$input' — controlled by genflake, use --update-repos to update" >&2
        continue
      fi
      if ! jq -e --arg name "$input" '(.nodes.root.inputs[$name] | type) == "string"' flake.lock >/dev/null; then
        echo "error: '$input' is not a declared input in the state flake.lock" >&2
        exit 1
      fi
      valid_inputs+=("$input")
    done
    for input in "${valid_inputs[@]}"; do
      nix flake update "$input"
    done
  )
fi

# Convergence: the genflake above ran with the bakes suppressed, so a PATCHED
# input still embeds its pre-bump tree. Re-run with the fresh lock and re-lock.
if [ "$update_repos_inputs" == "1" ] || [ "$update_all" == "1" ]; then
  # Sync FIRST: genflake reads the lock from ICEDOS_STATE_DIR.
  sync_lock
  flake_final=$(ICEDOS_UPDATE="" ICEDOS_UPDATE_MODULE_INPUTS="" \
    ICEDOS_STAGE="genflake" nix eval --raw $trace \
    --file "$ICEDOS_ROOT/lib/genflake.nix" flakeFinal)
  printf '%s\n' "$flake_final" >"$ICEDOS_STATE_DIR/$FLAKE"
  nixfmt "$ICEDOS_STATE_DIR/$FLAKE"
  # Re-lock the changed sub-flake roots; unchanged nodes keep their pins.
  rsync -a --exclude=".cache" "$ICEDOS_STATE_DIR/" "$lock_dir/"
  (
    set -e
    cd "$lock_dir"
    nix flake lock
  )
fi

# A failed lock step exits via the trap WITHOUT syncing, leaving `.state` on its
# previous lock; the next run re-attempts.
sync_lock

# Lets callers evaluate the generated flake without realising the closure.
if [ "$genflake_only" == "1" ]; then
  exit 0
fi

rm -rf "$lock_dir"
trap - EXIT

# Created here, not earlier: every path that exits before the build would
# otherwise leave an empty temp dir behind.
export ICEDOS_BUILD_DIR="$(mktemp -d -t icedos-build-XXXXXXX-0)"

# Held for the whole build so the nh-clean sweep skips this dir; released on
# exit, so a crashed build's dir is still collected next gc.
exec 9>"$ICEDOS_BUILD_DIR/.lock"
flock -n 9 || echo "warning: could not lock $ICEDOS_BUILD_DIR/.lock; a gc sweep may delete this build dir" >&2

rsync -a --exclude=".cache" "$ICEDOS_STATE_DIR/" "$ICEDOS_BUILD_DIR"
echo "building from path $ICEDOS_BUILD_DIR..."
cd $ICEDOS_BUILD_DIR

nh os $action --no-update-lock-file path:. "${nhBuildArgs[@]}" --hostname icedos -- $trace "${globalBuildArgs[@]}"

if [[ "$action" == "build-vm" ]]; then
  echo "VM configuration stored in $PWD/result"
fi

if [ "$run_vm" == "1" ]; then
  shopt -s nullglob
  vm_scripts=(result/bin/run-*-vm)
  shopt -u nullglob
  case ${#vm_scripts[@]} in
    0) echo "error: no VM script found in $PWD/result/bin" >&2; exit 1 ;;
    1) exec "${vm_scripts[0]}" ;;
    *) echo "error: expected exactly one VM script, got: ${vm_scripts[*]}" >&2; exit 1 ;;
  esac
fi
