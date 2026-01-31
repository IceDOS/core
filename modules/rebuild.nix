{
  config,
  pkgs,
  ...
}:

let
  builder =
    c: u:
    let
      inherit (pkgs) flatpak writeShellScript;
      flatpakUpdate = if (config.services.flatpak.enable) then "${flatpak}/bin/flatpak update" else "";
    in
    "${writeShellScript "${c}" ''
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
        echo -e "''${RED}error''${NC}: configuration path is invalid, run build.sh located inside the configuration scripts directory to update the path."
        exit 1
      fi


      if ${u}; then
        ${flatpakUpdate}
        bash ./build.sh --update $@
      else
        bash ./build.sh $@
      fi

      cache "../config.toml"
      cache "../flake.lock" ".config"
      cache "../flake.nix" ".config"
      cache "flake.lock" ".state"
      cache "flake.nix" ".state"
    ''}";
in
{
  icedos.applications.toolset.commands = [
    (
      let
        command = "rebuild";
      in
      {
        bin = toString (builder command "false");
        command = command;
        help = "rebuild the system";
      }
    )

    (
      let
        command = "update";
      in
      {
        bin = toString (builder command "true");
        command = command;
        help = "update flake.lock and rebuild the system";
      }
    )
  ];
}
