#! /usr/bin/env nix-shell
#! nix-shell -i bash -p git jq jsonfmt nh nixfmt-rfc-style rsync

ICEDOS_DIR="/tmp/icedos"
CONFIG="$ICEDOS_DIR/configuration-location"
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

nixBin=$(nix eval --impure --raw --expr "
    let pkgs = import <nixpkgs> {};
    in with builtins;
    if (compareVersions \"2.31.0\" pkgs.nix.version) > 0
    then toString (getFlake \"github:NixOS/nixpkgs/nixpkgs-unstable\").legacyPackages.\${pkgs.stdenv.hostPlatform.system}.nix
    else toString pkgs.nix
")
export PATH="$nixBin/bin:$PATH"

mkdir -p "$ICEDOS_DIR"

# Save current directory into a file
[ -f "$CONFIG" ] && rm -f "$CONFIG" || sudo rm -rf "$CONFIG"
printf "$PWD" > "$CONFIG"

# Generate flake.nix
[ -f "$FLAKE" ] && rm -f "$FLAKE"

export ICEDOS_FLAKE_INPUTS=$(mktemp)

[ "$update_repos" == "1" ] && refresh="--refresh"

ICEDOS_UPDATE="$update_repos" ICEDOS_STAGE="genflake" nix eval $refresh $trace --file "./lib/genflake.nix" flakeInputs | nixfmt | sed "1,1d" | sed "\$d" >$ICEDOS_FLAKE_INPUTS
(printf "{ inputs = {" ; cat $ICEDOS_FLAKE_INPUTS ; printf "}; outputs = { ... }: {}; }") >$FLAKE
nix flake prefetch-inputs

ICEDOS_STAGE="genflake" nix eval $trace --file "./lib/genflake.nix" --raw flakeFinal >$FLAKE
nixfmt "$FLAKE"

rm $ICEDOS_FLAKE_INPUTS
unset ICEDOS_FLAKE_INPUTS

if [ "$export_full_config" == "1" ]; then
  ICEDOS_STAGE="genflake" nix eval $trace --file "./lib/genflake.nix" evaluatedConfig | nixfmt | jq -r . > full-config.json
  jsonfmt ./full-config.json -w
  echo "Full config saved at $PWD/full-config.json"
  exit 0
fi

[ "$update" == "1" ] && nix flake update

# Make a tmp folder and build from there
TMP_BUILD_FOLDER="$(mktemp -d -t icedos-build-XXXXXXX-0 | xargs echo)/"

mkdir -p "$TMP_BUILD_FOLDER"

rsync -a ./ "$TMP_BUILD_FOLDER" \
--exclude='.cache' \
--exclude='.editorconfig' \
--exclude='.git' \
--exclude='.gitignore' \
--exclude='.lib' \
--exclude='.modules' \
--exclude='.taplo.toml' \
--exclude='LICENSE' \
--exclude='README.md' \
--exclude='build.sh'

echo "Building from path $TMP_BUILD_FOLDER"

# Build the system configuration
if (( ${#nixBuildArgs[@]} != 0 )) || [[ "$isFirstInstall" == 1 ]]; then
  sudo nixos-rebuild $action --flake .#"$(cat /etc/hostname)" $trace ${nixBuildArgs[*]} ${globalBuildArgs[*]}
  exit 0
fi

nh os $action "$TMP_BUILD_FOLDER" ${nhBuildArgs[*]} -- $trace ${globalBuildArgs[*]}
