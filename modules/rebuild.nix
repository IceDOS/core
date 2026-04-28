{
  config,
  icedosLib,
  pkgs,
  ...
}:

let
  inherit (pkgs) flatpak;
  inherit (icedosLib.bash) dimGreenString redString;
  flatpakUpdate = if (config.services.flatpak.enable) then "${flatpak}/bin/flatpak update" else "";
in
{
  icedos.applications.toolset.commands = [
    {
      command = "rebuild";
      help = "rebuild the system";

      script = ''
        CACHE_DIR=".cache"
        CACHED_NAMES=()

        cd "${config.icedos.configurationLocation}"

        LATEST_CACHE_FOLDER=$(ls -dt "$CACHE_DIR"/*/ 2>/dev/null | head -1)

        # Cache $1 (path) under name "$(basename $1)$2", appending it to
        # CACHED_NAMES if the content differs from the most recent cache.
        # Caller flushes the accumulated list once at the end so the user sees
        # one summary line instead of one per file.
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
            CACHED_NAMES+=("$NAME")
          fi
        }

        if [ ! -d "${config.icedos.configurationLocation}" ]; then
          echo -e "${redString "error"}: configuration path is invalid, execute 'nix run .' inside the configuration directory to update the path."
          exit 1
        fi

        for arg in "$@"; do
          if [ "$arg" = "--update" ]; then
            ${flatpakUpdate}
            break
          fi
        done

        bash ./build.sh "$@"
        BUILD_STATUS=$?

        if [ "$BUILD_STATUS" -ne 0 ]; then
          echo -e "${redString "error"}: build failed with exit code $BUILD_STATUS"
          exit "$BUILD_STATUS"
        fi

        cache "../config.toml"
        cache "../flake.lock" ".config"
        cache "../flake.nix" ".config"
        cache "flake.lock" ".state"
        cache "flake.nix" ".state"

        if [ ''${#CACHED_NAMES[@]} -gt 0 ]; then
          printf -v JOINED '%s, ' "''${CACHED_NAMES[@]}"
          echo -e "${dimGreenString ">"} Caching ''${JOINED%, }"
        fi
      '';
    }
  ];
}
