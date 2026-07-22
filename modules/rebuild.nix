{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash)
    dimGreenString
    prelude
    purpleString
    redString
    ;

  inherit (lib)
    concatStringsSep
    imap0
    optionalString
    ;

  inherit (config) icedos;
  inherit (icedos) configurationLocation;
  inherit (icedos.system.toolset.rebuild) hooks;

  inherit (hooks)
    postRebuild
    postUpdate
    preRebuild
    preUpdate
    ;

  # Compile each hook entry into its own pkgs.writeShellScript so it runs
  # in a fresh shell process. Isolates env/traps/`set -e`/`exit` from
  # other hooks and from the rebuild script itself. Prelude is injected
  # so hooks can use color vars (GREEN, NC, ...) and log helpers
  # (log_info, log_step, log_ok, log_warn, log_fail, die).
  runHooks =
    name: scripts:
    concatStringsSep "\n" (
      imap0 (
        i: s: "${pkgs.writeShellScript "icedos-hook-${name}-${toString i}" "${prelude}\n${s}"}"
      ) scripts
    );

  hasPreUpdate = preUpdate != [ ];
  hasPostUpdate = postUpdate != [ ];

  # Extra-config dirs (icedos.system.extraConfigs) as shell-quoted args, so the
  # snapshot machinery mirrors every configured config dir, not just `configs`.
  configDirsArgs = concatStringsSep " " (map lib.escapeShellArg icedos.system.extraConfigs);
in
{
  icedos.system.toolset.commands = [
    {
      command = "rebuild";
      help = "rebuild the system";

      script = ''
        CACHE_DIR=".cache"
        CACHED_NAMES=()
        CONFIG_DIRS=(${configDirsArgs})

        REBUILD_DIR=""
        args=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dir)
              REBUILD_DIR="$2"
              shift 2
              ;;
            *)
              args+=("$1")
              shift
              ;;
          esac
        done

        if [ -n "$REBUILD_DIR" ]; then
          if [ ! -d "$REBUILD_DIR" ]; then
            echo -e "${redString "error"}: directory '$REBUILD_DIR' does not exist"
            exit 1
          fi
          if [ ! -f "$REBUILD_DIR/flake.nix" ]; then
            echo -e "${redString "error"}: no flake.nix found in '$REBUILD_DIR'"
            exit 1
          fi
          cd "$REBUILD_DIR"
          nix run path:. -- "''${args[@]}"
          exit $?
        fi

        if [ ! -d "${configurationLocation}" ]; then
          printf -v PROMPT '%b' "${dimGreenString ">"} Configuration location (${configurationLocation}) does not exist. Use current directory ($PWD)? [y/N] "
          read -r -p "$PROMPT" ANSWER
          case "$ANSWER" in
            [yY]|[yY][eE][sS]) ;;
            *)
              echo -e "${redString "error"}: configuration path is invalid, execute 'nix run .' inside the configuration directory to update the path."
              exit 1
              ;;
          esac
          nix run path:. -- "''${args[@]}"
          exit $?
        fi

        cd "${configurationLocation}"

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

        # Latest snapshot folder carrying the .config-set marker — the anchor
        # that flags a folder as a config (not flake-only) snapshot. A marker,
        # not config.toml, because config.toml is optional (a root may be all
        # configs/*.toml + modules/).
        function latest_config_snapshot() {
          local d last=""
          shopt -s nullglob
          for d in "$CACHE_DIR"/*/; do
            [ -f "''${d}.config-set" ] && last="$d"
          done
          shopt -u nullglob
          printf '%s' "$last"
        }

        # True (0) when the working config set (config.toml + every *.toml,
        # including hidden .*.toml, under each CONFIG_DIRS entry) differs from
        # snapshot dir $1 (empty $1 = no snapshot).
        function config_set_changed() {
          local snap="$1" d f base
          [ -n "$snap" ] || return 0
          # config.toml is optional: changed if its presence or content differs.
          if [ -f "../config.toml" ]; then
            diff -q "../config.toml" "''${snap}config.toml" &> /dev/null || return 0
          elif [ -f "''${snap}config.toml" ]; then
            return 0
          fi
          shopt -s nullglob
          for d in "''${CONFIG_DIRS[@]}"; do
            for f in "../$d/"*.toml "../$d/".*.toml; do
              base="$(basename "$f")"
              diff -q "$f" "''${snap}$d/$base" &> /dev/null || { shopt -u nullglob; return 0; }
            done
            for f in "''${snap}$d/"*.toml "''${snap}$d/".*.toml; do
              base="$(basename "$f")"
              [ -f "../$d/$base" ] || { shopt -u nullglob; return 0; }
            done
          done
          shopt -u nullglob
          return 1
        }

        # Snapshot the config set as a unit (config.toml + every *.toml, including
        # hidden .*.toml, under each CONFIG_DIRS entry), preserving each dir's
        # layout, only when it changed — so `icedos configuration rollback` can
        # restore the exact config that built a generation. Note: hidden configs
        # may hold secrets/host overrides, so they are copied into the state cache
        # (readable there) as a consequence.
        function snapshot_config_set() {
          local snap folder d f
          snap="$(latest_config_snapshot)"
          config_set_changed "$snap" || return 0
          folder="$CACHE_DIR/$(date -Is)"
          mkdir -p "$folder"
          : > "$folder/.config-set"                 # anchor (config.toml may be absent)
          [ -f "../config.toml" ] && cp "../config.toml" "$folder/config.toml"
          shopt -s nullglob
          for d in "''${CONFIG_DIRS[@]}"; do
            for f in "../$d/"*.toml "../$d/".*.toml; do
              mkdir -p "$folder/$d"
              cp "$f" "$folder/$d/$(basename "$f")"
            done
          done
          shopt -u nullglob
          CACHED_NAMES+=("config set")
        }

        ${optionalString (hasPreUpdate || hasPostUpdate) ''
          # --update-hooks: run pre+post update hooks and exit. Skips
          # preRebuild/postRebuild, build.sh, cache, reboot check. For
          # refreshing non-nix things (flatpak, ...)
          # without a full system rebuild. ICEDOS_HOOKS_ONLY tells hooks
          # that no HM activation will follow, so they should fully
          # complete their work standalone.
          for arg in "''${args[@]}"; do
            if [ "$arg" = "--update-hooks" ]; then
              export ICEDOS_HOOKS_ONLY=1
              ${runHooks "preUpdate" preUpdate}
              ${runHooks "postUpdate" postUpdate}
              exit 0
            fi
          done
        ''}
        ${runHooks "preRebuild" preRebuild}
        ${optionalString hasPreUpdate ''
          for arg in "''${args[@]}"; do
            if [ "$arg" = "--update" ]; then
              ${runHooks "preUpdate" preUpdate}
              break
            fi
          done
        ''}
        bash ./build.sh "''${args[@]}"
        BUILD_STATUS=$?

        if [ "$BUILD_STATUS" -ne 0 ]; then
          echo -e "${redString "error"}: build failed with exit code $BUILD_STATUS"
          exit "$BUILD_STATUS"
        fi

        ${optionalString hasPostUpdate ''
          for arg in "''${args[@]}"; do
            if [ "$arg" = "--update" ]; then
              ${runHooks "postUpdate" postUpdate}
              break
            fi
          done
        ''}

        snapshot_config_set
        cache "../flake.lock" ".config"
        cache "../flake.nix" ".config"
        cache "flake.lock" ".state"
        cache "flake.nix" ".state"

        if [ ''${#CACHED_NAMES[@]} -gt 0 ]; then
          printf -v JOINED '%s, ' "''${CACHED_NAMES[@]}"
          echo -e "${dimGreenString ">"} Caching ''${JOINED%, }"
        fi

        # Record which config snapshot built the just-created generation so
        # `icedos configuration rollback` can restore the exact config set that
        # built it. Only switch/boot mint a new system generation; --build
        # never produces one so there is nothing to record.
        # build/build-vm/run-vm do not.
        GEN_CREATED=1
        for arg in "''${args[@]}"; do
          case "$arg" in
            --build|--build-vm|--run-vm) GEN_CREATED=""
            break
          esac
        done

        if [ "$GEN_CREATED" != "" ] && [ -e /nix/var/nix/profiles/system ]; then
          GEN="$(basename "$(readlink /nix/var/nix/profiles/system)" | sed 's/^system-\([0-9]*\)-link$/\1/')"
          shopt -s nullglob
          SNAP=""
          for d in "$CACHE_DIR"/*/; do
            [ -f "''${d}.config-set" ] && SNAP="$(basename "$d")"
          done
          shopt -u nullglob
          if [ -n "$GEN" ] && [ -n "$SNAP" ]; then
            mkdir -p "$CACHE_DIR/generations"
            printf '%s' "$SNAP" > "$CACHE_DIR/generations/$GEN"
          fi
        fi

        ${runHooks "postRebuild" postRebuild}

        # Skip reboot check when not switching (no activation happened).
        SWITCH=1
        for arg in "''${args[@]}"; do
          case "$arg" in
            --boot|--build|--build-vm|--run-vm) SWITCH=""
            break
          esac
        done

        if [ "$SWITCH" != "" ] \
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
            echo -e "${purpleString "warning"}: reboot recommended for ''${REASONS_JOINED%, } changes to apply"
            printf -v PROMPT '%b' "${dimGreenString ">"} Reboot now? [y/N] "
            read -r -p "$PROMPT" ANSWER
            case "$ANSWER" in
              [yY]|[yY][eE][sS]) systemctl reboot -i || sudo systemctl reboot -i ;;
            esac
          fi
        fi
      '';
    }
  ];
}
