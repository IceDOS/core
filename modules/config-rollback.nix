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
    purpleString
    redString
    ;

  inherit (config.icedos) configurationLocation;

  nh = "${pkgs.nh}/bin/nh";
  cacheDir = "${configurationLocation}/.cache";
  configRoot = "${configurationLocation}/..";
  workingConfig = "${configRoot}/config.toml";

  # Extra-config dirs (icedos.system.extraConfigs) as shell-quoted args.
  configDirsArgs = lib.concatStringsSep " " (
    map lib.escapeShellArg config.icedos.system.extraConfigs
  );
in
{
  icedos.system.toolset.configurationCommands = [
    {
      command = "rollback";
      help = "roll the system AND config set back to a previous generation";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos configuration rollback [--to <gen>] [--dry]"
          echo "Activates a previous generation (via nh) and restores the config set"
          echo "(config.toml + every *.toml under your config dirs, including hidden)"
          echo "that built it. Your current config set is backed up first."
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
        CONFIG_DIRS=(${configDirsArgs})
        snap_file="${cacheDir}/generations/$TARGET"
        if [ -f "$snap_file" ]; then snap="$(cat "$snap_file")"; else snap=""; fi
        snap_root="${cacheDir}/$snap"
        snap_toml="$snap_root/config.toml"

        store="$(readlink -f "$link")"
        ker="$(readlink "$store/kernel" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

        # Preview one working/snapshot file pair, indented under the plan. A
        # missing side shows as /dev/null so adds/removes are visible.
        show_pair() {
          local label="$1" work="$2" snapf="$3"
          [ -f "$work" ] || work=/dev/null
          [ -f "$snapf" ] || snapf=/dev/null
          if diff -q "$work" "$snapf" >/dev/null 2>&1; then
            echo "    $label: identical"
          else
            echo "    $label: would be restored"
            diff -u --color=always --label "current (working)" --label "gen $TARGET" \
              "$work" "$snapf" 2>/dev/null | sed 's/^/      /' || true
          fi
        }

        echo -e "${purpleString "Rollback plan"}"
        echo "  target generation: $TARGET  ($(date -d "@$m" '+%Y-%m-%d %H:%M'), kernel ''${ker:-?})"
        if [ -n "$snap" ] && [ -f "$snap_root/.config-set" ]; then
          echo "  config snapshot:   $snap (recorded at build)"
          echo
          echo "  config set changes that would be restored:"
          show_pair "config.toml" "${workingConfig}" "$snap_toml"
          shopt -s nullglob
          for d in "''${CONFIG_DIRS[@]}"; do
            for f in "$snap_root/$d/"*.toml "$snap_root/$d/".*.toml \
                     "${configRoot}/$d/"*.toml "${configRoot}/$d/".*.toml; do basename "$f"; done | sort -u \
              | while IFS= read -r b; do
                  [ -n "$b" ] || continue
                  show_pair "$d/$b" "${configRoot}/$d/$b" "$snap_root/$d/$b"
                done
          done
          shopt -u nullglob
        else
          echo -e "  ${redString "warning"}: no config snapshot recorded — this will be a SYSTEM-ONLY rollback (config left as-is)"
        fi
        echo
        echo "  note: hidden .*.toml (in your config dirs) are snapshotted too — secrets/host values land in the state cache."
        echo

        if [ "$DRY" -eq 1 ]; then
          echo "(dry run — nothing changed)"
          echo "would run: nh os rollback -t $TARGET"
          exit 0
        fi

        printf '%b' "${dimGreenString ">"} Roll back system + config set to generation $TARGET? [y/N] "
        read -r ans
        case "$ans" in
          [yY] | [yY][eE][sS]) ;;
          *)
            echo "aborted"
            exit 0
            ;;
        esac

        # Back up the live config set BEFORE anything mutates.
        backup_dir="${cacheDir}/rollback-backups/$(date -Is)"
        mkdir -p "$backup_dir"
        [ -f "${workingConfig}" ] && cp "${workingConfig}" "$backup_dir/config.toml"
        shopt -s nullglob
        for d in "''${CONFIG_DIRS[@]}"; do
          for f in "${configRoot}/$d/"*.toml "${configRoot}/$d/".*.toml; do
            mkdir -p "$backup_dir/$d"
            cp "$f" "$backup_dir/$d/$(basename "$f")"
          done
        done
        shopt -u nullglob
        echo "backed up current config set -> $backup_dir"

        # System first; config only if the system rollback succeeds.
        ${nh} os rollback -t "$TARGET" || die "nh os rollback failed — config set unchanged (backup at $backup_dir)"

        if [ -n "$snap" ] && [ -f "$snap_root/.config-set" ]; then
          # config.toml is optional — restore exactly: copy if snapshot carried
          # one, remove if it didn't (matching the config-dirs cleanup below).
          if [ -f "$snap_toml" ]; then
            cp "$snap_toml" "${workingConfig}"
          else
            rm -f "${workingConfig}"
          fi
          # Restore every config dir's *.toml set exactly (including hidden
          # .*.toml): copy snapshot files over, then drop working configs the
          # snapshot didn't carry.
          shopt -s nullglob
          for d in "''${CONFIG_DIRS[@]}"; do
            mkdir -p "${configRoot}/$d"
            for f in "$snap_root/$d/"*.toml "$snap_root/$d/".*.toml; do
              cp "$f" "${configRoot}/$d/$(basename "$f")"
            done
            for f in "${configRoot}/$d/"*.toml "${configRoot}/$d/".*.toml; do
              b="$(basename "$f")"
              [ -f "$snap_root/$d/$b" ] || rm -f "$f"
            done
          done
          shopt -u nullglob
          echo "restored config set from $snap"
        fi
        echo "done — system and config rolled back to generation $TARGET."
      '';
    }
  ];
}
