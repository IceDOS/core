{
  lib,
  ...
}:

let
  inherit (builtins)
    foldl'
    pathExists
    stringLength
    ;

  inherit (lib)
    concatStringsSep
    escapeShellArg
    fileContents
    max
    replaceStrings
    ;

in
{
  # Runtime helpers shared by Nix-embedded scripts (prelude auto-prepended by
  # toolset.nix) and standalone .sh files that source lib/prelude.sh.
  bash = {
    prelude = builtins.readFile ./prelude.sh;

    # PATH for systemd user services that shell out to host binaries and the
    # per-user profile; `~/.nix-profile/bin` is a harmless legacy fallback.
    exportSystemPath = ''
      base_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      nix_system_path="/run/current-system/sw/bin"
      nix_peruser_path="/etc/profiles/per-user/''${USER}/bin"
      nix_user_path="''${HOME}/.nix-profile/bin"
      export PATH="''${base_path}:''${nix_system_path}:''${nix_peruser_path}:''${nix_user_path}:$PATH"
    '';

    genHelpFlags =
      {
        excludeNoArgs ? false,
      }:
      let
        base = ''"$1" == "--help" || "$1" == "-h" || "$1" == "help" || "$1" == "h"'';
      in
      if excludeNoArgs then base else ''"$1" == "" || '' + base;

    # Bash arg parser from a Nix flag spec, spliced into a script body. Emits a
    # `die` polyfill for standalone consumers (toolset leaves get the prelude).
    mkFlags =
      {
        prefix,
        flags,
        passthroughUnknown ? false,
      }:
      let
        # Map flag name to bash variable name (e.g. "gpu-layers" → "LLAMACPP_GPU_LAYERS")
        toVarName = name: "${prefix}_${lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name)}";

        # Map flag name to "was set" tracking variable
        toSetVar = name: "${toVarName name}_SET";

        # Short flag pattern for case arm, e.g. "-H|" or ""
        shortPat = f: if f ? short then "-${f.short}|" else "";

        # Flag spec for help text alignment
        flagSpec =
          f:
          let
            shortPart = if f ? short then "-${f.short}, " else "    ";
            flagPart = "--${f.name}";
            typePart =
              if f.type == "string" then
                " <string>"
              else if f.type == "int" then
                " <int>"
              else if f.type == "bool" then
                ""
              else if f.type == "enum" then
                " <${lib.concatStringsSep "|" f.choices}>"
              else
                "";
          in
          "${shortPart}${flagPart}${typePart}";

        # Compute max flag spec width for alignment
        maxSpecLen = foldl' max 0 (map (f: stringLength (flagSpec f)) flags);

        # Help text line for one flag
        helpLine =
          f:
          let
            spec = flagSpec f;
            pad = maxSpecLen - stringLength spec + 2;
            defaultHelp =
              if f.type == "bool" then
                if f.default then "true" else "false"
              else if f.type == "int" then
                toString (builtins.floor f.default)
              else
                toString f.default;
          in
          "  ${spec}${
              lib.concatStringsSep "" (lib.genList (_: " ") pad)
            }${f.description} (default: ${defaultHelp})";

        # Full help text with real newlines
        helpText = "Flags:\n${lib.concatStringsSep "\n" (map helpLine flags)}";

        # Escaped default value for bash
        escDefault =
          f:
          if f.type == "bool" then
            if f.default then "true" else "false"
          else if f.type == "int" then
            lib.escapeShellArg (toString (builtins.floor f.default))
          else
            lib.escapeShellArg (toString f.default);

        # Variable declarations for one flag
        varDecl = f: "${toVarName f.name}=${escDefault f}\n${toSetVar f.name}=0";

        # Generate case arms for one flag
        genCaseArm =
          f:
          let
            var = toVarName f.name;
            svar = toSetVar f.name;
            long = "--${f.name}";
            sp = shortPat f;
          in
          if f.type == "bool" then
            ''
              ${sp}${long})
                ${var}="true"; ${svar}=1
                shift
                ;;
              --no-${f.name})
                ${var}="false"; ${svar}=1
                shift
                ;;
              ${long}=true|${long}=false)
                ${var}="''${1#${long}=}"; ${svar}=1
                shift
                ;;
            ''
          else
            ''
              ${sp}${long})
                [[ $# -ge 2 ]] || die "${long} requires a value"
                ${lib.optionalString (
                  f.type == "int"
                ) ''[[ "$2" =~ ^-?[0-9]+$ ]] || die "${long} must be an integer"''}
                ${lib.optionalString (f.type == "enum") ''
                  case "$2" in
                    ${lib.concatStringsSep "|" f.choices}) ;;
                    *) die "invalid value for ${long}: $2 (choose: ${lib.concatStringsSep ", " f.choices})" ;;
                  esac
                ''}
                ${var}="$2"; ${svar}=1
                shift 2
                ;;
              ${long}=*)
                v="''${1#${long}=}"
                ${lib.optionalString (
                  f.type == "int"
                ) ''[[ "$v" =~ ^-?[0-9]+$ ]] || die "${long} must be an integer"''}
                ${lib.optionalString (f.type == "enum") ''
                  case "$v" in
                    ${lib.concatStringsSep "|" f.choices}) ;;
                    *) die "invalid value for ${long}: $v (choose: ${lib.concatStringsSep ", " f.choices})" ;;
                  esac
                ''}
                ${var}="$v"; ${svar}=1
                shift
                ;;
            '';

        shorts = lib.filter (s: s != null) (map (f: if f ? short then f.short else null) flags);
      in
      assert lib.assertMsg (lib.all (n: builtins.match "^[a-z0-9-]+$" n != null) (
        map (f: f.name) flags
      )) "mkFlags (${prefix}): flag names must match [a-z0-9-]+";
      assert lib.assertMsg (lib.all (
        s: builtins.match "^[a-zA-Z0-9-]+$" s != null
      ) shorts) "mkFlags (${prefix}): short flags must match [a-zA-Z0-9-]+";
      assert lib.assertMsg (
        lib.length (lib.unique (map (f: toVarName f.name) flags)) == lib.length flags
      ) "mkFlags (${prefix}): duplicate variable names generated";
      assert lib.assertMsg (
        lib.length (lib.unique shorts) == lib.length shorts
      ) "mkFlags (${prefix}): duplicate short flags";
      assert lib.assertMsg (
        !(lib.elem "help" (map (f: f.name) flags))
      ) "mkFlags (${prefix}): 'help' is a reserved flag name";
      assert lib.assertMsg (!(lib.elem "h" shorts)) "mkFlags (${prefix}): 'h' is a reserved short flag";
      ''
                if ! declare -F die >/dev/null 2>&1; then
                  die() { printf 'error: %s\n' "$*" >&2; exit 1; }
                fi

                ${lib.concatStringsSep "\n" (map varDecl flags)}

                _HELP_TEXT=$(cat <<'__ICEDOS_MKFLAGS_EOF__'
        ${helpText}
        __ICEDOS_MKFLAGS_EOF__
                )

                _REST=()
                while [[ $# -gt 0 ]]; do
                  case "$1" in
                    -h|--help)
                      echo "$_HELP_TEXT"
                      exit 0
                      ;;
                    ${lib.concatStringsSep "\n" (map genCaseArm flags)}
                    --)
                      shift
                      _REST+=("$@")
                      break
                      ;;
                    ${
                      if passthroughUnknown then
                        ''
                          -*)
                            _REST+=("$1")
                            shift
                            ;;
                        ''
                      else
                        ''
                          -*)
                            die "unknown flag: $1"
                            ;;
                        ''
                    }
                    *)
                      _REST+=("$1")
                      shift
                      ;;
                  esac
                done
                set -- "''${_REST[@]}"
      '';

    blueString = s: "\${BLUE}${s}\${NC}";
    greenString = s: "\${GREEN}${s}\${NC}";
    purpleString = s: "\${PURPLE}${s}\${NC}";
    redString = s: "\${RED}${s}\${NC}";
    yellowString = s: "\${YELLOW}${s}\${NC}";

    dimBlueString = s: "\${DIM_BLUE}${s}\${NC}";
    dimGreenString = s: "\${DIM_GREEN}${s}\${NC}";
    dimPurpleString = s: "\${DIM_PURPLE}${s}\${NC}";
    dimRedString = s: "\${DIM_RED}${s}\${NC}";
    dimYellowString = s: "\${DIM_YELLOW}${s}\${NC}";

    # Shared by `icedos configuration` diff/rollback/history: pairs a snapshot
    # folder against the working tree over the same config-set file list.
    configSet =
      config:
      let
        inherit (config.icedos) configurationLocation;
        configRoot = "${configurationLocation}/..";
        workingConfig = "${configRoot}/config.toml";
        configDirsArgs = concatStringsSep " " (map escapeShellArg config.icedos.system.extraConfigs);
      in
      {
        inherit configRoot workingConfig configDirsArgs;
        cacheDir = "${configurationLocation}/.cache";

        # `walk_config_set <root> <fn>` calls fn per file in the UNION of both
        # sides (added/removed included), in the caller's shell so fn can set vars.
        walk = ''
          CONFIG_DIRS=(${configDirsArgs})

          walk_config_set() {
            local root="''${1%/}" fn="$2" d b names f
            "$fn" "config.toml" "$root/config.toml" "${workingConfig}"
            shopt -s nullglob
            for d in "''${CONFIG_DIRS[@]}"; do
              names="$(
                for f in "$root/$d/"*.toml "$root/$d/".*.toml \
                         "${configRoot}/$d/"*.toml "${configRoot}/$d/".*.toml; do
                  basename "$f"
                done | sort -u
              )"
              while IFS= read -r b; do
                [ -n "$b" ] || continue
                "$fn" "$d/$b" "$root/$d/$b" "${configRoot}/$d/$b"
              done <<< "$names"
            done
            shopt -u nullglob
          }
        '';
      };

    # Sets gc_age/gc_dt from the nh-clean timer's LastTriggerUSec (persists
    # across reboots), or leaves them empty. Callers set `now` and format.
    gcTimerCheckSnippet = { systemctl }: ''
      last=$(${systemctl} show nh-clean.timer -p LastTriggerUSec --value --timestamp=unix 2>/dev/null)
      ts="''${last#@}"
      if [ -n "$ts" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
        gc_age=$(((now - ts) / 86400))
        gc_dt=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")
      else
        gc_age=""
        gc_dt=""
      fi
    '';

    # Permission guard: running another user's baked build.sh executes their code
    # as the invoker (or root). Args: config root, state dir, ORIGINAL args.
    requireConfigOwner = ''
      require_config_owner() {
        local root="$1" state_dir="$2" orig="$1" owner me state answer rc PROMPT readable probe warn_suffix owner_home owner_path
        shift 2
        # `test -d` cannot tell absent from inaccessible (a 0700 parent fails with
        # EACCES), so probe with stat and treat only ENOENT as absent.
        root=$(realpath -m "$root" 2>/dev/null) || root="$orig"
        warn_suffix=""
        if ! owner=$(LC_ALL=C stat -c %U "$root" 2>&1); then
          case "$owner" in
            *'No such file or directory'* | *'Not a directory'* | *'not a directory'*)
              return 0
              ;;
          esac
          # Inaccessible — walk up to the first stat-able ancestor to find
          # who owns the tree this command would execute.
          owner=""
          probe="$root"
          while [ -n "$probe" ] && [ "$probe" != "/" ]; do
            if owner=$(stat -c %U "$probe" 2>/dev/null); then
              break
            fi
            case "$probe" in
              */*) probe="''${probe%/*}" ;;
              *) break ;;
            esac
          done
          [ -n "$owner" ] || return 0
          warn_suffix=" (nearest accessible ancestor)"
        fi
        me=$(id -un)
        state="''${state_dir:-$root/.state}"

        # Re-entered after an owner re-run — never prompt again, or unrelated
        # sudo hops could ping-pong between users.
        if [ -n "''${ICEDOS_OWNER_RERUN:-}" ]; then
          return 0
        fi

        if [ -r "$root" ] && [ -x "$root" ] \
           && { [ ! -e "$state" ] || { [ -r "$state" ] && [ -x "$state" ]; }; }; then
          readable=1
        else
          readable=0
        fi

        if [ "$owner" != "$me" ]; then
          # Another user's config root — warn whoever runs it, even when
          # readable, so they know whose build.sh executes as them.
          echo -e "''${YELLOW}warning''${NC}: configuration root '$root' is owned by '$owner'$warn_suffix; running it as '$me'." >&2
          # Root always prompts: `test -r`/`-x` pass for uid 0, so readability
          # alone would let root silently run another user's build.sh.
          if [ "$readable" = "0" ] || [ "$(id -u)" -eq 0 ]; then
            echo "         Re-running as '$owner' executes that user's build.sh with '$me' privileges." >&2
            if [ -t 0 ]; then
              printf -v PROMPT '%b' "''${DIM_GREEN}>''${NC} Run 'icedos' as '$owner'? [y/N] "
              read -r -p "$PROMPT" answer
              case "$answer" in
                [yY]|[yY][eE][sS]) ;;
                # Root must abort: every test passes for uid 0, so no caller
                # fall-through would stop the build. Non-root falls through flagged.
                *)
                  if [ "$(id -u)" -eq 0 ]; then
                    die "aborted: declined to execute the configuration root of '$owner' as root"
                  fi
                  ICEDOS_OWNER_DECLINED=1
                  return 0
                  ;;
              esac
            else
              # Unattended: an unreadable root aborts; an accessible one proceeds
              # (already warned), so scripted rebuilds that elevate still work.
              [ "$readable" = "0" ] && die "aborted: no permission to configuration root '$root' (owned by '$owner')"
              return 0
            fi

            if [ "$(id -u)" -eq 0 ]; then
              # `runuser` would inherit root's HOME/PATH and break the owner's nix,
              # so pin the identity and a login PATH via `env -i` (mirrors nh.nix).
              owner_home=$(getent passwd "$owner" | cut -d: -f6)
              [ -n "$owner_home" ] || owner_home="/home/$owner"
              owner_path="/run/wrappers/bin:$owner_home/.nix-profile/bin:$owner_home/.local/state/nix/profile/bin:/etc/profiles/per-user/$owner/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
              /run/current-system/sw/bin/runuser -u "$owner" -- \
                /run/current-system/sw/bin/env -i "HOME=$owner_home" "USER=$owner" "LOGNAME=$owner" "PATH=$owner_path" \
                ICEDOS_OWNER_RERUN=1 "ICEDOS_TIP_ACTIVE=''${ICEDOS_TIP_ACTIVE:-}" "$0" "$@"
            else
              # sudo resets the env, so pass the re-entry marker explicitly; only
              # the setuid wrapper path works here.
              /run/wrappers/bin/sudo -u "$owner" -- /run/current-system/sw/bin/env ICEDOS_OWNER_RERUN=1 "ICEDOS_TIP_ACTIVE=''${ICEDOS_TIP_ACTIVE:-}" "$0" "$@"
            fi
            rc=$?
            [ "$rc" -eq 0 ] && exit 0
            echo "re-run as '$owner' exited with $rc" >&2
            exit "$rc"
          fi
          return 0
        fi

        # Same owner, but the config isn't readable — they'll likely hit a
        # confusing build failure, so point at the permissions up front.
        if [ "$readable" = "0" ]; then
          echo -e "''${YELLOW}warning''${NC}: you do not have read/execute permission on configuration root '$root'." >&2
          echo "         Fix the permissions before running 'icedos rebuild' — the build will fail otherwise." >&2
        fi
        return 0
      }
    '';

    # Bottom bar for toolset leaves: one random tip pinned to the last line and
    # command output confined to the scroll region above it; TTY-only.
    printTip =
      tips:
      let
        enabled = tips.enable && tips.list != [ ];
        # The tip is printed onto one pinned row, so a newline from a `"""…"""`
        # tip in config.toml would scroll the screen and tear the region open.
        oneLine = replaceStrings [ "\n" "\r" "\t" ] [ " " " " " " ];
        tipLine =
          t:
          if builtins.isString t then
            "💡: ${t}"
          else if !(t ? title) then
            "💡: ${t.message}"
          else if t.title == "" then
            t.message
          else
            "${t.title}: ${t.message}";
        head = ''
          _icedos_tips=(
            ${concatStringsSep "
" (map (t: escapeShellArg (oneLine (tipLine t))) tips.list)}
          )
          _icedos_tip_shown=0
          _icedos_tip_i=0
          _icedos_bar=0
          _icedos_tip_plain=0
          _icedos_rows=
          _icedos_max=
          _icedos_cpr_row=
          _icedos_cpr_col=
          # A cursor-position reply that misses the timeout would otherwise
          # surface as stray keystrokes in the next `read` a leaf runs.
          _icedos_drain_tty() {
            local junk
            read -rs -t 0.05 -n 4096 junk </dev/tty 2>/dev/null
            read -rs -t 0.05 -n 4096 junk </dev/tty 2>/dev/null
            return 0
          }
          # Row and col come back empty when the terminal does not answer, or
          # answers with something that is not a CPR.
          _icedos_cpr() {
            local p c
            _icedos_cpr_row=
            _icedos_cpr_col=
            printf '\033[6n' >/dev/tty 2>/dev/null
            if IFS=';' read -rsdR -t 0.2 p c </dev/tty 2>/dev/null; then
              p=''${p##*[}
              p=''${p%%;*}
              c=''${c%%R*}
              case "$p" in
                "" | *[!0-9]*) p= ;;
              esac
              case "$c" in
                "" | *[!0-9]*) c= ;;
              esac
            else
              p=
              c=
            fi
            [ -n "$p" ] || _icedos_drain_tty
            _icedos_cpr_row=$p
            _icedos_cpr_col=$c
            return 0
          }
          _icedos_tip_init() {
            [ -t 1 ] || return 0
            # A parent leaf already pinned the bar (nested icedos call, or an
            # owner re-run that carried the marker): keep the outer bar.
            [ -n "''${ICEDOS_TIP_ACTIVE:-}" ] && return 0
            local size rows cols max p n i
            size=$(stty size </dev/tty 2>/dev/null) || size=""
            rows=''${size%% *}
            cols=''${size##* }
            [ "$rows" -ge 4 ] 2>/dev/null || rows=$(tput lines </dev/tty 2>/dev/null || echo 24)
            [ "$rows" -ge 4 ] 2>/dev/null || rows=24
            # `cols - 2` is a substring length: 0 blanks the bar and a negative
            # value means "all but the last N chars", so keep it at least 1.
            [ "$cols" -ge 3 ] 2>/dev/null || cols=80
            _icedos_rows=$rows
            _icedos_max=$(( cols - 2 ))
            _icedos_tip_i=$(( RANDOM % ''${#_icedos_tips[@]} ))
            export ICEDOS_TIP_ACTIVE=1
            _icedos_cpr
            p=$_icedos_cpr_row
            if [ -z "$p" ]; then
              # Scrolling blind would wipe the screen, so drop the bar and
              # degrade to a plain tip line printed on exit.
              _icedos_tip_plain=1
              return 0
            fi
            max=$_icedos_max
            _icedos_bar=1
            n=0
            if [ "$p" -ge "$((rows - 2))" ] 2>/dev/null; then
              n=$(( p - rows + 3 ))
            fi
            if [ "$n" -gt 0 ]; then
              # The prompt sits where the bar and its blank row go, so scroll it
              # up by that overlap instead of drawing over the command line.
              printf '\033[%d;1H' "$rows"
              i=$n
              while [ "$i" -gt 0 ]; do printf '\n'; i=$((i - 1)); done
            fi
            # Autowrap off around the tip: a tip wider than the terminal would
            # otherwise wrap into the scroll region and push output up a row.
            printf '\033[?7l\033[%d;1H\033[K%b%s%b\033[?7h' "$rows" "$DIM_GREEN" "''${_icedos_tips[$_icedos_tip_i]:0:$max}" "$NC"
            printf '\033[%d;1H\033[K' "$((rows - 1))"
            printf '\033[1;%dr' "$((rows - 2))"
            # One line below the prompt, corrected for the rows just scrolled:
            # setting the region homed the cursor, so it has to be placed back.
            printf '\033[%d;1H' "$(( p + 1 - n ))"
          }
          # A resize leaves the region and bar at stale coordinates. Bash defers
          # this until the foreground command returns, so a build holds it stale.
          _icedos_tip_winch() {
            [ "$_icedos_tip_shown" -eq 1 ] && return 0
            [ -t 1 ] || return 0
            [ "$_icedos_bar" = 1 ] || return 0
            local size rows cols max p c
            size=$(stty size </dev/tty 2>/dev/null) || size=""
            rows=''${size%% *}
            cols=''${size##* }
            [ "$rows" -ge 4 ] 2>/dev/null || return 0
            [ "$cols" -ge 3 ] 2>/dev/null || return 0
            max=$(( cols - 2 ))
            [ "$rows" = "$_icedos_rows" ] && [ "$max" = "$_icedos_max" ] && return 0
            local old_rows=$_icedos_rows
            _icedos_rows=$rows
            _icedos_max=$max
            _icedos_cpr
            p=$_icedos_cpr_row
            c=$_icedos_cpr_col
            printf '\033[r'
            printf '\033[?7l\033[%d;1H\033[K%b%s%b\033[?7h' "$rows" "$DIM_GREEN" "''${_icedos_tips[$_icedos_tip_i]:0:$max}" "$NC"
            printf '\033[%d;1H\033[K' "$((rows - 1))"
            printf '\033[1;%dr' "$((rows - 2))"
            # Growing puts the old bar rows inside the region; clear that band so
            # resumed output cannot fuse with the text left there.
            if [ "$rows" -gt "$old_rows" ]; then
              local r
              r=$((old_rows - 1))
              while [ "$r" -le "$old_rows" ]; do
                printf '\033[%d;1H\033[K' "$r"
                r=$((r + 1))
              done
            fi
            if [ -n "$p" ] && [ "$p" -le "$((rows - 2))" ] 2>/dev/null && [ -n "$c" ]; then
              # Back to where output was, clamped: a narrower terminal leaves the
              # pre-resize column past the new right edge.
              [ "$c" -gt "$cols" ] 2>/dev/null && c=$cols
              printf '\033[%d;%dH' "$p" "$c"
            else
              printf '\033[1;1H'
            fi
          }
          _icedos_tip() {
            [ "$_icedos_tip_shown" -eq 1 ] && return 0
            _icedos_tip_shown=1
            trap - WINCH
            # Children spawned after the bar is gone (an exec'd program that
            # calls icedos again) must be free to pin a bar of their own.
            unset ICEDOS_TIP_ACTIVE
            [ -t 1 ] || return 0
            if [ "$_icedos_tip_plain" = 1 ]; then
              printf '%b%s%b\n' "$DIM_GREEN" "''${_icedos_tips[$_icedos_tip_i]}" "$NC"
              return 0
            fi
            [ "$_icedos_bar" = 1 ] || return 0
            local size rows
            size=$(stty size </dev/tty 2>/dev/null) || size=""
            rows=''${size%% *}
            [ "$rows" -ge 4 ] 2>/dev/null || rows=$_icedos_rows
            # Newline on the bar's own row scrolls it up one, so the shell prompt
            # lands below the tip instead of overwriting it.
            printf '\033[r\033[%d;1H\n' "$rows"
          }
          _icedos_tip_init
          trap _icedos_tip EXIT
          # Signal death must also restore the region (SIGKILL cannot); the
          # explicit exits give leaves the usual 128+SIG status.
          trap '_icedos_tip; exit $((128 + 15))' TERM
          trap '_icedos_tip; exit $((128 + 1))' HUP
          trap '_icedos_tip; exit $((128 + 3))' QUIT
          trap _icedos_tip_winch WINCH

        '';
      in
      if !enabled then
        {
          head = "";
          foot = "";
        }
      else
        {
          inherit head;
          foot = "_icedos_tip_rc=$?\n_icedos_tip\nexit \"$_icedos_tip_rc\"\n";
        };
  };

  injectIfExists =
    { file }:
    if (pathExists file) then
      ''
        (
          ${fileContents file}
        )
      ''
    else
      "";

}
