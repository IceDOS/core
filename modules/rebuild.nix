{
  config,
  pkgs,
  ...
}:

let
  inherit (pkgs) flatpak writeShellScript;
  flatpakUpdate = if (config.services.flatpak.enable) then "${flatpak}/bin/flatpak update" else "";

  rebuild = writeShellScript "rebuild" ''
    RED='\033[0;31m'
    NC='\033[0m'
    CACHE_DIR=".cache"

    cd "${config.icedos.configurationLocation}"

    LATEST_CACHE_FOLDER=$(ls -dt "$CACHE_DIR"/*/ 2>/dev/null | head -1)

    function cache() {
      IS_CACHED=0
      FILE="$1"
      NAME="$(basename $1)$2"

      if [ -n "$LATEST_CACHE_FOLDER" ]; then
        CACHED_FILE=$(find "$LATEST_CACHE_FOLDER" -name "$NAME" | head -1)

        if [ -f "$CACHED_FILE" ]; then
          if diff -q "$FILE" "$CACHED_FILE" &> /dev/null; then
            IS_CACHED=1
          fi
        fi
      fi

      if [[ ! "$IS_CACHED" -eq 1 ]]; then
        DATE_FOLDER="$CACHE_DIR/$(date -Is)"
        mkdir -p "$DATE_FOLDER"
        cp "$FILE" "$DATE_FOLDER/$NAME"
      fi
    }

    if [ ! -d "${config.icedos.configurationLocation}" ]; then
      echo -e "''${RED}error''${NC}: configuration path is invalid, execute 'nix run .' inside the configuration directory to update the path."
      exit 1
    fi

    for arg in "$@"; do
      if [ "$arg" = "--update" ]; then
        ${flatpakUpdate}
        break
      fi
    done

    bash ./build.sh "$@"

    cache "../config.toml"
    cache "../flake.lock" ".config"
    cache "../flake.nix" ".config"
    cache "flake.lock" ".state"
    cache "flake.nix" ".state"
  '';
in
{
  icedos.applications.toolset.commands = [
    {
      command = "rebuild";
      bin = toString rebuild;
      help = "rebuild the system";
    }
  ];
}
