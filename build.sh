#!/usr/bin/env bash

export NIXPKGS_ALLOW_UNFREE=1

ICEDOS_DIR="/tmp/icedos"
CONFIG="$ICEDOS_DIR/configuration-location"
FLAKE="flake.nix"

cd "$(dirname "$(readlink -f "$0")")"

action="switch"
globalBuildArgs=()
nhBuildArgs=()

set -e
set -o pipefail

previous_arguments=("$@")

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
    --export-full-config)
      export_full_config=1
      shift
      ;;
    --update)
      update_all="1"
      update_core="1"
      update_nixpkgs="1"
      update_repos="1"
      update_repos_inputs="1"
      shift
      ;;
    --update-core)
      update_core="1"
      shift
      ;;
    --update-nixpkgs)
      update_nixpkgs="1"
      shift
      ;;
    --update-repos)
      update_repos="1"
      shift
      ;;
    --update-repos-inputs)
      update_repos_inputs="1"
      shift
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

# Refresh every `type: "path"` input in config/flake.lock so a local-
# core override (inputs.icedos.url = "path:...") lands on every plain
# rebuild without requiring --update-core. github / git inputs stay
# pinned. Skipped when --update-core is set since the block below
# does a full --refresh on all inputs anyway.
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

if [[ "$update_core" == "1" && -z "$skip_update_core" ]]; then
  cd "$ICEDOS_CONFIG_ROOT"
  nix flake update --refresh
  exec env skip_update_core=1 nix run path:. -- "${previous_arguments[@]}"
  exit 0
fi

mkdir -p "$ICEDOS_DIR"

# Save current directory into a file
[ -f "$CONFIG" ] && rm -f "$CONFIG" || sudo rm -rf "$CONFIG"
printf '%s' "$ICEDOS_STATE_DIR" > "$CONFIG"

if [ "$update_repos" == "1" ]; then
  refresh="--refresh"
fi

export ICEDOS_BUILD_DIR="$(mktemp -d -t icedos-build-XXXXXXX-0)"
mkdir -p "$ICEDOS_BUILD_DIR"

# Generate flake
ICEDOS_UPDATE="$update_repos" ICEDOS_STAGE="genflake" nix eval $refresh $trace --file "$ICEDOS_ROOT/lib/genflake.nix" --raw flakeFinal >"$ICEDOS_STATE_DIR/$FLAKE"
nixfmt "$ICEDOS_STATE_DIR/$FLAKE"

(
  set -e
  cd "$ICEDOS_STATE_DIR"

  if [ ! -f flake.lock ] || [ -n "$update_core$update_nixpkgs$update_repos$update_repos_inputs" ]; then
    nix flake prefetch-inputs
  fi

  # Refresh every `type: "path"` input on each build so local sibling-
  # repo edits (e.g. overrideUrl = "path:..." in config.toml) land
  # without requiring --update-repos. github / git inputs stay pinned
  # to their lock entries so we don't pay a network roundtrip per
  # rebuild.
  for input in $(jq -r '.nodes | to_entries[] | select(.value.locked.type == "path") | .key' flake.lock 2>/dev/null); do
    nix flake update "$input" 2>/dev/null || true
  done

  [ "$update_core" == "1" ] && nix flake update icedos-core --refresh 2>/dev/null || true
)

if [ "$update_all" == "1" ]; then
  (
    set -e
    cd "$ICEDOS_STATE_DIR"
    nix flake update --refresh
  )
elif [ "$update_repos_inputs" == "1" ]; then
  (
    set -e
    cd "$ICEDOS_STATE_DIR"
    for input in $(jq -r '
      .nodes.root.inputs
      | to_entries[]
      | select(.value | type == "string")
      | .key
      | select(startswith("icedos-"))
    ' flake.lock 2>/dev/null); do
      nix flake update "$input" --refresh 2>/dev/null || true
    done
  )
fi

if [ "$export_full_config" == "1" ]; then
  (
    cd "$ICEDOS_STATE_DIR"
    ICEDOS_STAGE="genflake" nix eval $trace --file "$ICEDOS_ROOT/lib/genflake.nix" evaluatedConfig | nixfmt | jq -r . > .cache/full-config.json
    jsonfmt .cache/full-config.json -w

    toml2json "$ICEDOS_CONFIG_ROOT/config.toml" > .cache/config.json
    jsonfmt .cache/config.json -w
  )

  exit 0
fi

[ "$update_nixpkgs" == "1" ] && [ "$update_all" != "1" ] && (
  set -e
  cd "$ICEDOS_STATE_DIR"
  nix flake update nixpkgs
)

rsync -a --exclude=".cache" "$ICEDOS_STATE_DIR/" "$ICEDOS_BUILD_DIR"
echo "building from path $ICEDOS_BUILD_DIR..."
cd $ICEDOS_BUILD_DIR

nh os $action --no-update-lock-file path:. "${nhBuildArgs[@]}" --hostname "$(cat /etc/hostname)" -- $trace "${globalBuildArgs[@]}"

if [[ "$action" == "build-vm" ]]; then
  echo "VM configuration stored in $PWD/result"
fi

if [ "$run_vm" == "1" ]; then
  exec "result/bin/run-$(cat /etc/hostname)-vm"
fi
