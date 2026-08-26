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
    genHelpFlags
    prelude
    purpleString
    redString
    requireConfigOwner
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

  # One script per hook, so each runs in a fresh shell (isolated env/traps/exit)
  # with the prelude available.
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
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos rebuild [flags]"
          echo
          echo "Flags:"
          echo "  --dry, -n, --dry-run      validate flake generation without building"
          echo "                            (regenerates .state/flake.nix, refreshes path input"
          echo "                            locks; does NOT evaluate nixosConfigurations so"
          echo "                            module-body errors remain out of scope)"
          echo "  --logs                    show full build log with --show-trace"
          echo "  --dir <dir>               use alternate config directory"
          echo "  --update                  update everything (core, nixpkgs, repos, repo inputs) + run update hooks"
          echo "  --update-hooks            run update hooks only (pre+post), no build"
          echo "  --build                   build closure without switching"
          echo "  --boot                    build and set as boot entry"
          echo "  --update-core             update all config flake inputs before rebuild"
          echo "  --update-core-only        update only icedos input before rebuild"
          echo "  --update-state-inputs <list> update specific state flake inputs before rebuild"
          echo "  --update-repos            update repos + their inputs before rebuild"
          echo "  --update-repos-only       update repos only before rebuild"
          echo "  --update-repo-inputs-only update repo inputs only before rebuild"
          echo "  --build-vm                build a VM test image"
          echo "  --run-vm                  build and run a VM test image"
          echo "  --genflake-only           generate .state/flake.nix and exit (--dry's underlying mechanism)"
          echo "  --ask                     ask for confirmation before applying (nh os -a)"
          echo "  --builder <host>          build the system on a remote host"
          echo "  --target <host>           deploy/activate the built system on a remote host"
          echo "  --nh-args ...             forward extra args to nh os (consumes until --build-args)"
          echo "  --build-args ...          forward all remaining args to the final rebuild command (must be last)"
          echo "  --help                    show this message"
          exit 0
        fi

        ORIG_ARGS=("$@")
        ${requireConfigOwner}
        CACHE_DIR=".cache"
        CACHED_NAMES=()
        CONFIG_DIRS=(${configDirsArgs})

        DRY=0
        REBUILD_DIR=""
        args=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dir)
              REBUILD_DIR="$2"
              shift 2
              ;;
            --dry|--dry-run|-n)
              DRY=1
              shift
              ;;
            --build-args)
              args+=("$1")
              shift
              while [[ $# -gt 0 ]]; do
                args+=("$1")
                shift
              done
              ;;
            --nh-args)
              args+=("$1")
              shift
              while [[ $# -gt 0 ]] && [[ "$1" != "--build-args" ]]; do
                args+=("$1")
                shift
              done
              ;;
            *)
              args+=("$1")
              shift
              ;;
           esac
        done

        [ "$DRY" = "1" ] && args=("--genflake-only" "''${args[@]}")

        # Strip --update-hooks early so every dispatch path (--dir, normal)
        # sees clean args — under DRY it would be rejected by build.sh.
        if [ "$DRY" = "1" ]; then
          filtered=()
          for arg in "''${args[@]}"; do
            if [ "$arg" = "--update-hooks" ]; then
              log_warn "--update-hooks ignored under --dry"
            else
              filtered+=("$arg")
            fi
          done
          args=("''${filtered[@]}")
        fi

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

        require_config_owner "${configurationLocation}/.." "${configurationLocation}" "''${ORIG_ARGS[@]}"

        if [ ! -d "${configurationLocation}" ]; then
          if [ -n "''${ICEDOS_OWNER_DECLINED:-}" ]; then
            die "no permission to access configuration path '${configurationLocation}'; run it as the owning user or fix the permissions."
          fi
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

        cd "${configurationLocation}" || die "no permission to enter '${configurationLocation}'; run it as the owning user or fix the permissions."

        LATEST_CACHE_FOLDER=$(ls -dt "$CACHE_DIR"/*/ 2>/dev/null | head -1)

        # Caches $1 when its content changed, accumulating CACHED_NAMES so the
        # caller can print one summary line instead of one per file.
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

        # Keyed on the .config-set marker, not config.toml — config.toml is
        # optional.
        function latest_config_snapshot() {
          local d last=""
          shopt -s nullglob
          for d in "$CACHE_DIR"/*/; do
            [ -f "''${d}.config-set" ] && last="$d"
          done
          shopt -u nullglob
          printf '%s' "$last"
        }

        # True (0) when the working config set differs from snapshot dir $1
        # (empty $1 = no snapshot).
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

        # Snapshot the whole config set (hidden .*.toml included — gitignored, not
        # secret) when it changed, so rollback can restore it exactly.
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
          if [ "$DRY" != "1" ]; then
            # --update-hooks: pre+post update hooks only, no build. ICEDOS_HOOKS_ONLY
            # tells hooks no HM activation follows, so they must stand alone.
            for arg in "''${args[@]}"; do
              if [ "$arg" = "--update-hooks" ]; then
                export ICEDOS_HOOKS_ONLY=1
                ${runHooks "preUpdate" preUpdate}
                ${runHooks "postUpdate" postUpdate}
                exit 0
              fi
            done
          fi
        ''}
        if [ "$DRY" = "1" ]; then
          log_step "dry run — generating flake..."
          bash ./build.sh "''${args[@]}"; rc=$?
          if [ "$rc" -eq 0 ]; then
            log_ok "dry run — flake generated and inputs locked (module eval not checked)"
          fi
          exit "$rc"
        fi
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

        # Only switch/boot mint a generation, so only they record which snapshot
        # built it (for `icedos configuration rollback`).
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
