#!/usr/bin/env bash

export NIXPKGS_ALLOW_UNFREE=1

ICEDOS_DIR="/tmp/icedos"
CONFIG="$ICEDOS_DIR/configuration-location"
FLAKE="flake.nix"

cd "$(dirname "$(readlink -f "$0")")"

action="switch"
globalBuildArgs=()
nhBuildArgs=()
nixBuildArgs=()

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
    --export-full-config)
      export_full_config=1
      shift
      ;;
    --update)
      update_core="1"
      update_nix="1"
      update_repos="1"
      shift
      ;;
    --update-core)
      update_core="1"
      shift
      ;;
    --update-nix)
      update_nix="1"
      shift
      ;;
    --update-repos)
      update_repos="1"
      shift
      ;;
    --ask)
      nhBuildArgs+=("-a")
      shift
      ;;
    --builder)
      nixBuildArgs+=("--build-host")
      nixBuildArgs+=("$2")
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

mkdir -p "$ICEDOS_DIR"

export ICEDOS_BUILD_DIR="$(mktemp -d -t icedos-build-XXXXXXX-0)"
mkdir -p "$ICEDOS_BUILD_DIR"

# Save current directory into a file
[ -f "$CONFIG" ] && rm -f "$CONFIG" || sudo rm -rf "$CONFIG"
printf '%s' "$ICEDOS_STATE_DIR" > "$CONFIG"

if [ "$update_repos" == "1" ]; then
  refresh="--refresh"
fi

if [[ "$update_core" == "1" && -z "$skip_update_core" ]]; then
  cd "$ICEDOS_CONFIG_ROOT"
  nix flake update
  exec env skip_update_core=1 nix run . -- "${previous_arguments[@]}"
  exit 0
fi

# Generate flake inputs
ICEDOS_FLAKE_INPUTS_JSON="$(ICEDOS_UPDATE="$update_repos" ICEDOS_STAGE="genflake" nix build $refresh $trace --no-link --print-out-paths --file "$ICEDOS_ROOT/lib/genflake.nix" flakeInputsJson)"
export ICEDOS_FLAKE_INPUTS="$(cat $ICEDOS_FLAKE_INPUTS_JSON | json2nix | sed "1,1d" | sed "\$d")"
if [[ "${ICEDOS_FLAKE_INPUTS}" == "" ]]; then
  exit 1
fi
echo "{ inputs = { $ICEDOS_FLAKE_INPUTS }; outputs = { ... }: { }; }" >"$ICEDOS_STATE_DIR/$FLAKE"
(
  set -e
  cd "$ICEDOS_STATE_DIR"
  nix flake prefetch-inputs
  nix flake update icedos-config 2>/dev/null || true
  nix flake update icedos-state 2>/dev/null || true
)

# Generate flake
ICEDOS_STAGE="genflake" nix eval $trace --file "$ICEDOS_ROOT/lib/genflake.nix" --raw flakeFinal >"$ICEDOS_STATE_DIR/$FLAKE"
nixfmt "$ICEDOS_STATE_DIR/$FLAKE"

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

[ "$update_nix" == "1" ] && (
  set -e
  cd "$ICEDOS_STATE_DIR"
  nix flake update
)

rsync -a "$ICEDOS_CONFIG_ROOT" "$ICEDOS_BUILD_DIR" \
--exclude='.editorconfig' \
--exclude='.git' \
--exclude='.gitignore' \
--exclude='.state/.cache' \
--exclude='.taplo.toml' \
--exclude='LICENSE' \
--exclude='README.md' \
--exclude='flake.lock' \
--exclude='flake.nix'

cp "$ICEDOS_STATE_DIR"/* "$ICEDOS_BUILD_DIR"

echo "Building from path $ICEDOS_BUILD_DIR"
cd $ICEDOS_BUILD_DIR

# Build the system configuration
if (( ${#nixBuildArgs[@]} != 0 )); then
  sudo nixos-rebuild $action --flake .#"$(cat /etc/hostname)" --no-update-lock-file $trace "${nixBuildArgs[@]}" "${globalBuildArgs[@]}"
  exit 0
fi

nh os $action --no-update-lock-file . "${nhBuildArgs[@]}" -- $trace "${globalBuildArgs[@]}"
