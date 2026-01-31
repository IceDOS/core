#!/usr/bin/env bash

ICEDOS_DIR="/tmp/icedos"
CONFIG="$ICEDOS_DIR/configuration-location"
FLAKE="flake.nix"

cd "$(dirname "$(readlink -f "$0")")"
FLAKE="flake.nix"

action="switch"
globalBuildArgs=()
nhBuildArgs=()
nixBuildArgs=()
isFirstInstall=""

set -e

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
      update="1"
      update_repos="1"
      shift
      ;;
    --update-nix)
      update="1"
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
    --first-install)
      isFirstInstall=1
      shift
      ;;
    --logs)
      export ICEDOS_LOGGING=1
      trace="--show-trace"
      shift
      ;;
    -*|--*)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

export NIX_CONFIG="experimental-features = flakes nix-command"

mkdir -p "$ICEDOS_DIR"

export ICEDOS_BUILD_DIR="$(mktemp -d -t icedos-build-XXXXXXX-0)"
mkdir -p "$ICEDOS_BUILD_DIR"

# Save current directory into a file
[ -f "$CONFIG" ] && rm -f "$CONFIG" || sudo rm -rf "$CONFIG"
printf "$ICEDOS_STATE_DIR" > "$CONFIG"

if [ "$update_repos" == "1" ]; then
  refresh="--refresh"
  (cd "$ICEDOS_CONFIG_ROOT" ; nix flake update)
fi

export ICEDOS_FLAKE_INPUTS="$(ICEDOS_UPDATE="$update_repos" ICEDOS_STAGE="genflake" nix eval $refresh $trace --file "$ICEDOS_ROOT/lib/genflake.nix" flakeInputs | nixfmt | sed "1,1d" | sed "\$d")"
echo "{ inputs = { $ICEDOS_FLAKE_INPUTS }; outputs = { ... }: { }; }" >"$ICEDOS_STATE_DIR/$FLAKE"
(
  cd "$ICEDOS_STATE_DIR"
  nix flake prefetch-inputs
  nix flake update icedos-config 2>/dev/null || true
)

ICEDOS_STAGE="genflake" nix eval $trace --file "$ICEDOS_ROOT/lib/genflake.nix" --raw flakeFinal >"$ICEDOS_STATE_DIR/$FLAKE"
nixfmt "$ICEDOS_STATE_DIR/$FLAKE"

if [ "$export_full_config" == "1" ]; then
  ICEDOS_STAGE="genflake" nix eval $trace --file "./lib/genflake.nix" evaluatedConfig | nixfmt | jq -r . > .cache/full-config.json
  jsonfmt .cache/full-config.json -w

  toml2json ./config.toml > .cache/config.json
  jsonfmt .cache/config.json -w

  exit 0
fi

[ "$update" == "1" ] && (
  set -e
  cd "$ICEDOS_STATE_DIR"
  nix flake update
)

rsync -a "$ICEDOS_CONFIG_ROOT" "$ICEDOS_BUILD_DIR" \
--exclude='.git' \
--exclude='.gitignore' \
--exclude='flake.lock' \
--exclude='flake.nix' \
--exclude='LICENSE' \
--exclude='README.md'

cp "$ICEDOS_STATE_DIR"/* "$ICEDOS_BUILD_DIR"

echo "Building from path $ICEDOS_BUILD_DIR"
cd $ICEDOS_BUILD_DIR

# Build the system configuration
if (( ${#nixBuildArgs[@]} != 0 )) || [[ "$isFirstInstall" == 1 ]]; then
  sudo nixos-rebuild $action --flake .#"$(cat /etc/hostname)" $trace ${nixBuildArgs[*]} ${globalBuildArgs[*]}
  exit 0
fi

nh os $action . ${nhBuildArgs[*]} -- $trace ${globalBuildArgs[*]}
