{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash) dimGreenString prelude redString;
  hooks = config.icedos.applications.toolset.rebuild.hooks;

  # Compile each hook entry into its own pkgs.writeShellScript so it runs
  # in a fresh shell process. Isolates env/traps/`set -e`/`exit` from
  # other hooks and from the rebuild script itself. Prelude is injected
  # so hooks can use color vars (GREEN, NC, ...) and log helpers
  # (log_info, log_step, log_ok, log_warn, log_fail, die).
  runHooks =
    name: scripts:
    lib.concatStringsSep "\n" (
      lib.imap0 (
        i: s: "${pkgs.writeShellScript "icedos-hook-${name}-${toString i}" "${prelude}\n${s}"}"
      ) scripts
    );

  hasPreUpdate = hooks.preUpdate != [ ];
  hasPostUpdate = hooks.postUpdate != [ ];
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

        ${lib.optionalString (hasPreUpdate || hasPostUpdate) ''
          # --update-hooks: run pre+post update hooks and exit. Skips
          # preRebuild/postRebuild, build.sh, cache, reboot check. For
          # refreshing non-nix things (flatpak, millennium themes, ...)
          # without a full system rebuild. ICEDOS_HOOKS_ONLY tells hooks
          # that no HM activation will follow, so they should fully
          # complete their work standalone.
          for arg in "$@"; do
            if [ "$arg" = "--update-hooks" ]; then
              export ICEDOS_HOOKS_ONLY=1
              ${runHooks "preUpdate" hooks.preUpdate}
              ${runHooks "postUpdate" hooks.postUpdate}
              exit 0
            fi
          done
        ''}
        ${runHooks "preRebuild" hooks.preRebuild}
        ${lib.optionalString hasPreUpdate ''
          for arg in "$@"; do
            if [ "$arg" = "--update" ]; then
              ${runHooks "preUpdate" hooks.preUpdate}
              break
            fi
          done
        ''}
        bash ./build.sh "$@"
        BUILD_STATUS=$?

        if [ "$BUILD_STATUS" -ne 0 ]; then
          echo -e "${redString "error"}: build failed with exit code $BUILD_STATUS"
          exit "$BUILD_STATUS"
        fi

        ${lib.optionalString hasPostUpdate ''
          for arg in "$@"; do
            if [ "$arg" = "--update" ]; then
              ${runHooks "postUpdate" hooks.postUpdate}
              break
            fi
          done
        ''}

        cache "../config.toml"
        cache "../flake.lock" ".config"
        cache "../flake.nix" ".config"
        cache "flake.lock" ".state"
        cache "flake.nix" ".state"

        if [ ''${#CACHED_NAMES[@]} -gt 0 ]; then
          printf -v JOINED '%s, ' "''${CACHED_NAMES[@]}"
          echo -e "${dimGreenString ">"} Caching ''${JOINED%, }"
        fi

        ${runHooks "postRebuild" hooks.postRebuild}

        # Skip reboot check on --boot / --build (no activation happened).
        ACTION="switch"
        for arg in "$@"; do
          case "$arg" in
            --boot)  ACTION="boot"  ;;
            --build) ACTION="build" ;;
          esac
        done

        if [ "$ACTION" = "switch" ] \
           && [ -d /run/booted-system ] \
           && [ -d /run/current-system ]; then
          REBOOT_REASONS=()
          for component in kernel initrd; do
            booted=$(readlink -f "/run/booted-system/$component" 2>/dev/null || true)
            current=$(readlink -f "/run/current-system/$component" 2>/dev/null || true)
            [ -n "$booted" ] && [ -n "$current" ] || continue
            cmp -s "$booted" "$current" || REBOOT_REASONS+=("$component")
          done

          if [ ''${#REBOOT_REASONS[@]} -gt 0 ]; then
            printf -v REASONS_JOINED '%s, ' "''${REBOOT_REASONS[@]}"
            echo
            echo -e "${redString "reboot recommended"}: ''${REASONS_JOINED%, } changed"
            read -r -p "Reboot now? [y/N] " ANSWER
            case "$ANSWER" in
              [yY]|[yY][eE][sS]) sudo systemctl reboot -i ;;
            esac
          fi
        fi
      '';
    }
  ];
}
