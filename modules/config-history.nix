{
  config,
  icedosLib,
  ...
}:

let
  inherit (icedosLib.bash)
    configSet
    genHelpFlags
    purpleString
    redString
    ;

  inherit (configSet config) cacheDir walk;
in
{
  icedos.system.toolset.configurationCommands = [
    {
      command = "history";
      help = "browse config snapshots tied to system generations";

      completion.command = ''
        ls -1d /nix/var/nix/profiles/system-*-link 2>/dev/null \
          | sed 's|.*/system-\([0-9]*\)-link|\1|' | sort -rn
      '';

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos configuration history [--json | <gen>]"
          echo "Lists system generations newest first, with dates, kernels, age and"
          echo "whether the config snapshot that built each one is still on disk."
          echo "Available arguments:"
          echo -e "> ${purpleString "<gen>"}: show the config diff between that generation's snapshot and the working tree"
          echo -e "> ${purpleString "--json"}: emit the generation table as JSON (cannot be combined with <gen>)"
          exit 0
        fi

        JSON=0
        TARGET=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --json)
              JSON=1
              shift
              ;;
            -*)
              echo -e "${redString "Unknown arg"}: $1" >&2
              exit 1
              ;;
            *)
              [ -z "$TARGET" ] || die "only one generation can be given (got '$TARGET' and '$1')"
              TARGET="$1"
              shift
              ;;
          esac
        done

        [ "$JSON" -eq 1 ] && [ -n "$TARGET" ] &&
          die "--json cannot be combined with a generation"

        # Snapshot state for generation $1, as recorded by rebuild.nix:
        #   present — the pointer and the snapshot folder both exist
        #   pruned  — a snapshot was recorded but is gone from the cache (gc'd)
        #   none    — no snapshot was ever recorded for this generation
        snapshot_state() {
          local gen="$1" ptr snap
          ptr="${cacheDir}/generations/$gen"
          if [ ! -f "$ptr" ]; then
            printf 'none'
            return
          fi
          snap="$(cat "$ptr")"
          if [ -n "$snap" ] && [ -f "${cacheDir}/$snap/.config-set" ]; then
            printf 'present'
          else
            printf 'pruned'
          fi
        }

        # Named lookup: show the config diff for one generation.
        if [ -n "$TARGET" ]; then
          printf '%s' "$TARGET" | grep -Eq '^[0-9]+$' || die "invalid generation: $TARGET"
          link="/nix/var/nix/profiles/system-''${TARGET}-link"
          [ -e "$link" ] || die "generation $TARGET not found"

          case "$(snapshot_state "$TARGET")" in
            none) die "no config snapshot recorded for generation $TARGET" ;;
            pruned) die "config snapshot for generation $TARGET is no longer in the cache (pruned)" ;;
          esac
          snap_root="${cacheDir}/$(cat "${cacheDir}/generations/$TARGET")"

          m="$(stat -c %Y "$link" 2>/dev/null)"
          echo "Config diff: working tree vs generation $TARGET ($(date -d "@''${m:-0}" '+%Y-%m-%d %H:%M'))"
          echo

          ${walk}

          differs=0
          diff_pair() {
            local label="$1" snapf="$2" work="$3"
            [ -f "$work" ] || work=/dev/null
            [ -f "$snapf" ] || snapf=/dev/null
            if ! diff -q "$snapf" "$work" >/dev/null 2>&1; then
              differs=1
              diff -u --color=always --label "gen $TARGET: $label" --label "working: $label" \
                "$snapf" "$work" || true
            fi
          }

          walk_config_set "$snap_root" diff_pair

          if [ "$differs" -eq 0 ]; then
            log_ok "no config differences — working tree matches generation $TARGET"
          fi
          exit 0
        fi

        # Generation numbers, newest first. Sorted numerically: the profile glob
        # is lexical, which misorders mixed digit widths (99 vs 100).
        mapfile -t gens < <(
          ls -1d /nix/var/nix/profiles/system-*-link 2>/dev/null \
            | sed 's|.*/system-\([0-9]*\)-link|\1|' | sort -rn
        )
        [ ''${#gens[@]} -gt 0 ] || die "no system generations found"

        current="$(basename "$(readlink /nix/var/nix/profiles/system)" 2>/dev/null \
          | sed 's/^system-\([0-9]*\)-link$/\1/')"

        now=$(date +%s)
        json_rows=()

        [ "$JSON" -eq 1 ] || printf '%b%s%-5s %-18s %-12s %-6s %s%b\n' \
          "$PURPLE" " " "GEN" "DATE" "KERNEL" "AGE" "SNAP" "$NC"

        for gen in "''${gens[@]}"; do
          link="/nix/var/nix/profiles/system-''${gen}-link"
          m="$(stat -c %Y "$link" 2>/dev/null)"
          [ -n "$m" ] || m=0
          store="$(readlink -f "$link")"
          ker="$(readlink "$store/kernel" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
          age=$(((now - m) / 86400))
          dt="$(date -d "@$m" '+%Y-%m-%d %H:%M')"
          state="$(snapshot_state "$gen")"

          if [ "$JSON" -eq 1 ]; then
            cur=false
            [ "$gen" = "$current" ] && cur=true
            json_rows+=("{\"gen\":$gen,\"date\":\"$dt\",\"kernel\":\"''${ker:-}\",\"snapshot\":\"$state\",\"current\":$cur,\"ageDays\":$age}")
            continue
          fi

          case "$state" in
            present) icon="''${GREEN}✓''${NC}" ;;
            pruned) icon="''${RED}✗''${NC}" ;;
            *) icon="-" ;;
          esac
          mark=" "
          [ "$gen" = "$current" ] && mark="*"

          printf '%s%-5s %-18s %-12s %-6s %b\n' \
            "$mark" "$gen" "$dt" "''${ker:-?}" "''${age}d" "$icon"
        done

        if [ "$JSON" -eq 1 ]; then
          joined=$(printf ',%s' "''${json_rows[@]}")
          echo "[ ''${joined#,} ]"
        fi
      '';
    }
  ];
}
