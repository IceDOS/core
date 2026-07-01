{
  config,
  icedosLib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash)
    dimGreenString
    genHelpFlags
    purpleString
    redString
    ;

  inherit (config.icedos) configurationLocation;

  nh = "${pkgs.nh}/bin/nh";
  cacheDir = "${configurationLocation}/.cache";
  workingConfig = "${configurationLocation}/../config.toml";
in
{
  icedos.system.toolset.configurationCommands = [
    {
      command = "rollback";
      help = "roll the system AND config.toml back to a previous generation";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos configuration rollback [--to <gen>] [--dry]"
          echo "Activates a previous generation (via nh) and restores the config.toml"
          echo "that built it. Your current config.toml is backed up first."
          echo "Available arguments:"
          echo -e "> ${purpleString "--to <gen>"}: target generation number (default: the previous one)"
          echo -e "> ${purpleString "--dry"}: show the plan without changing anything"
          exit 0
        fi

        DRY=0
        TARGET=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --to)
              TARGET="$2"
              shift 2
              ;;
            --dry | -n)
              DRY=1
              shift
              ;;
            *)
              echo -e "${redString "Unknown arg"}: $1" >&2
              exit 1
              ;;
          esac
        done

        current_n="$(basename "$(readlink /nix/var/nix/profiles/system)" | sed 's/^system-\([0-9]*\)-link$/\1/')"
        [ -n "$TARGET" ] || TARGET=$((current_n - 1))

        printf '%s' "$TARGET" | grep -Eq '^[0-9]+$' || die "invalid generation: $TARGET"
        link="/nix/var/nix/profiles/system-''${TARGET}-link"
        [ -e "$link" ] || die "generation $TARGET not found"
        [ "$TARGET" = "$current_n" ] && die "generation $TARGET is already current"

        # Resolve the config snapshot that built the target generation from the
        # exact marker the rebuild script records at build time. Generations
        # built before the marker existed have none — those roll back system-only.
        m="$(stat -c %Y "$link" 2>/dev/null)"
        snap_file="${cacheDir}/generations/$TARGET"
        if [ -f "$snap_file" ]; then snap="$(cat "$snap_file")"; else snap=""; fi
        snap_toml="${cacheDir}/$snap/config.toml"

        store="$(readlink -f "$link")"
        ker="$(readlink "$store/kernel" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

        echo -e "${purpleString "Rollback plan"}"
        echo "  target generation: $TARGET  ($(date -d "@$m" '+%Y-%m-%d %H:%M'), kernel ''${ker:-?})"
        if [ -n "$snap" ] && [ -f "$snap_toml" ]; then
          echo "  config snapshot:   $snap (recorded at build)"
          echo
          if diff -q "${workingConfig}" "$snap_toml" >/dev/null 2>&1; then
            echo "  config.toml: identical — nothing to restore"
          else
            echo "  config.toml changes that would be restored:"
            diff -u --color=always --label "current (working)" --label "gen $TARGET" "${workingConfig}" "$snap_toml" 2>/dev/null | sed 's/^/    /' || true
          fi
        else
          echo -e "  ${redString "warning"}: no config snapshot recorded — this will be a SYSTEM-ONLY rollback (config.toml left as-is)"
        fi
        echo
        echo "  note: .private.toml is not snapshotted — secret/host overrides are not restored."
        echo

        if [ "$DRY" -eq 1 ]; then
          echo "(dry run — nothing changed)"
          echo "would run: nh os rollback -t $TARGET"
          exit 0
        fi

        printf '%b' "${dimGreenString ">"} Roll back system + config.toml to generation $TARGET? [y/N] "
        read -r ans
        case "$ans" in
          [yY] | [yY][eE][sS]) ;;
          *)
            echo "aborted"
            exit 0
            ;;
        esac

        # Back up the live config.toml BEFORE anything mutates.
        backup_dir="${cacheDir}/rollback-backups"
        mkdir -p "$backup_dir"
        backup="$backup_dir/config.toml.$(date -Is)"
        cp "${workingConfig}" "$backup"
        echo "backed up current config.toml -> $backup"

        # System first; config only if the system rollback succeeds.
        ${nh} os rollback -t "$TARGET" || die "nh os rollback failed — config.toml unchanged (backup at $backup)"

        if [ -n "$snap" ] && [ -f "$snap_toml" ]; then
          cp "$snap_toml" "${workingConfig}"
          echo "restored config.toml from $snap"
        fi
        echo "done — system and config.toml rolled back to generation $TARGET."
      '';
    }
  ];
}
