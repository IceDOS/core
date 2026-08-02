{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash)
    configSet
    dimBlueString
    dimGreenString
    dimRedString
    dimYellowString
    genHelpFlags
    prelude
    ;

  inherit (configSet config) cacheDir;

  inherit (lib)
    concatMap
    concatStringsSep
    escapeShellArg
    imap0
    mkIf
    ;

  inherit (pkgs) writeShellScript writeShellScriptBin;

  bc = "${pkgs.bc}/bin/bc";
  flock = "${pkgs.util-linux}/bin/flock";

  inherit (config.icedos.system) gc;
  inherit (gc)
    automatic
    cache
    hooks
    interval
    ;
  inherit (hooks) postGc preGc;
  inherit (config.icedos) users;

  days = "${toString gc.days}d";
  generations = toString gc.generations;

  cleanExtra =
    let
      command = "nh-clean-extra";
    in
    "${writeShellScriptBin command ''
      ${prelude}

      _phase="both"
      _summary_file=""
      DRY=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --preview|-p) _phase=preview; shift ;;
          --remove|-r)  _phase=remove; shift ;;
          --summary-file) [ $# -ge 2 ] || die "--summary-file value required"; _summary_file="$2"; shift 2 ;;
          -n|--dry-run) DRY="-n"; shift ;;
          *) die "nh-clean-extra: unknown arg: $1" ;;
        esac
      done

      declare -a tempBuildDirs=()
      while IFS= read -r -d $'\0' dir; do
        tempBuildDirs+=("$dir")
      done < <(find /tmp -type d -name 'icedos-build*' -print0 2>/dev/null)

      # A build dir held by an active build has a `.lock` file that build.sh
      # keeps flocked for the whole build. Releasing happens automatically on
      # process exit/crash, so a stale dir is deletable; only a live build is
      # skipped. A dir without `.lock` (e.g. left by an older build.sh) is
      # treated as stale and deletable. Unreadable dirs (another user's
      # build; `mktemp -d` uses mode 0700) are skipped as not ours.
      declare -a buildDirs=()
      declare -a inFlightDirs=()
      for dir in "''${tempBuildDirs[@]}"; do
        if [ ! -r "$dir" ] || [ ! -x "$dir" ] || { [ -e "$dir/.lock" ] && ! ${flock} -n "$dir/.lock" true 2>/dev/null; }; then
          inFlightDirs+=("$dir")
        else
          buildDirs+=("$dir")
        fi
      done

      totalSize=0
      buildPathsCount=0

      for dir in "''${buildDirs[@]}"; do
        sizeKb=$(du -sk "$dir" | cut -f1)
        sizeMb=$(echo "scale=2; $sizeKb / 1024" | ${bc})
        totalSize=$(echo "scale=2; $totalSize + $sizeMb" | ${bc})
        buildPathsCount=$(( buildPathsCount + 1 ))
      done

      formattedTotal=$(printf "%.2f" "$totalSize")
      _summary_line="''$buildPathsCount build path''$([ $buildPathsCount != 1 ] && echo s) deleted, ''${formattedTotal} MiB freed"

      if [ "$_phase" != remove ] && ( [ "$buildPathsCount" -gt 0 ] || [ "''${#inFlightDirs[@]}" -gt 0 ] ); then
        echo -e "${dimBlueString "/tmp/icedos-build*"}"
        for dir in "''${buildDirs[@]}"; do
          if [ -n "$DRY" ]; then
            echo -e "- ${dimRedString "would DEL"} $dir"
          else
            echo -e "- ${dimRedString "DEL"} $dir"
          fi
        done
        for dir in "''${inFlightDirs[@]}"; do
          echo -e "- ${dimYellowString "skip"} $dir (build in flight or not ours)"
        done
        echo
      fi

      if [ "$_phase" != preview ] && [ "$buildPathsCount" -gt 0 ]; then
        for dir in "''${buildDirs[@]}"; do
          if [ -z "$DRY" ]; then
            echo -e "${dimGreenString ">"} Removing $dir"
            rm -r "$dir"
          fi
        done
        if [ -n "$DRY" ]; then
          _summary_line="''$buildPathsCount build path''$([ $buildPathsCount != 1 ] && echo s) would be deleted, ''${formattedTotal} MiB would be freed"
        fi
        if [ -n "$_summary_file" ]; then
          echo "$_summary_line" > "$_summary_file"
        else
          echo "$_summary_line"
        fi
      fi
    ''}/bin/${command}";

  cacheCleanScript =
    let
      command = "nh-cache-clean";
    in
    "${writeShellScriptBin command ''
      ${prelude}

      GC_DAYS=${toString cache.days}
      GC_GENS=${toString cache.generations}
      DRY=""
      _phase="both"
      _summary_file=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --days|-d) [ $# -ge 2 ] || die "cacheClean: --days value required"; GC_DAYS="$2"; shift 2 ;;
          --gens|-g) [ $# -ge 2 ] || die "cacheClean: --gens value required"; GC_GENS="$2"; shift 2 ;;
          --preview|-p) _phase=preview; shift ;;
          --remove|-r)  _phase=remove; shift ;;
          --summary-file) [ $# -ge 2 ] || die "cacheClean: --summary-file value required"; _summary_file="$2"; shift 2 ;;
          -n|--dry-run) DRY="-n"; shift ;;
          *) die "cacheClean: unknown arg: $1" ;;
        esac
      done

      [[ "$GC_DAYS" =~ ^[0-9]+$ ]] || die "cacheClean: --days must be a non-negative integer, got: $GC_DAYS"
      [[ "$GC_GENS" =~ ^[0-9]+$ ]] || die "cacheClean: --gens must be a non-negative integer, got: $GC_GENS"

      CACHE_DIR="${cacheDir}"
      [ -d "$CACHE_DIR" ] || exit 0
      cd "$CACHE_DIR" || exit 0

      shopt -s nullglob
      declare -a SNAPSHOTS=()
      for d in */; do
        name=''${d%/}
        case "$name" in generations|rollback-backups) continue ;; esac
        ts=$(date -d "$name" +%s 2>/dev/null) || true
        [ -n "$ts" ] || { log_warn "skipping unparseable dir $name"; continue; }
        SNAPSHOTS+=("$name")
      done
      shopt -u nullglob

      [ ''${#SNAPSHOTS[@]} -eq 0 ] && exit 0

      newest_ts=0
      newest_config_set=""
      for sd in "''${SNAPSHOTS[@]}"; do
        [ -f "$sd/.config-set" ] || continue
        ts=$(date -d "$sd" +%s 2>/dev/null) || continue
        [ "$ts" -gt "$newest_ts" ] && { newest_ts=$ts; newest_config_set="$sd"; }
      done

      declare -a LIVE_FOLDERS=()
      if [ -d "generations" ]; then
        shopt -s nullglob
        for gf in generations/*; do
          gen=''${gf##*/}
          [ -e "/nix/var/nix/profiles/system-$gen-link" ] || continue
          snap=$(cat "$gf" 2>/dev/null) || continue
          LIVE_FOLDERS+=("$snap")
        done
        shopt -u nullglob
      fi

      declare -a KEEP=() DELETE=()
      for sd in "''${SNAPSHOTS[@]}"; do
        keep=0
        [ -n "$newest_config_set" ] && [ "$sd" = "$newest_config_set" ] && keep=1
        for lf in "''${LIVE_FOLDERS[@]}"; do
          [ "$sd" = "$lf" ] && { keep=1; break; }
        done
        [ "$keep" -eq 1 ] && KEEP+=("$sd") || DELETE+=("$sd")
      done

      if [ ''${#DELETE[@]} -gt 0 ]; then
        declare -a EPOCH_ENTRIES=()
        for sd in "''${DELETE[@]}"; do
          ts=$(date -d "$sd" +%s 2>/dev/null) || ts=0
          EPOCH_ENTRIES+=("$ts|$sd")
        done
        IFS=$'\n' SORTED_LINES=($(printf '%s\n' "''${EPOCH_ENTRIES[@]}" | sort -t'|' -k1,1n))
        unset IFS
        declare -a DELETE_SORTED=()
        for line in "''${SORTED_LINES[@]}"; do
          DELETE_SORTED+=("''${line#*|}")
        done
      else
        declare -a DELETE_SORTED=()
      fi
      if [ "$GC_GENS" -gt 0 ] && [ ''${#DELETE_SORTED[@]} -gt 0 ]; then
        keep_count=$GC_GENS
        [ ''${#DELETE_SORTED[@]} -le "$keep_count" ] && keep_count=''${#DELETE_SORTED[@]}
        start=$(( ''${#DELETE_SORTED[@]} - keep_count ))
        for (( i=start; i < ''${#DELETE_SORTED[@]}; i++ )); do
          KEEP+=("''${DELETE_SORTED[$i]}")
        done
        declare -a NEW_DELETE=()
        for sd in "''${DELETE_SORTED[@]}"; do
          found=0
          for kd in "''${KEEP[@]}"; do
            [ "$sd" = "$kd" ] && { found=1; break; }
          done
          [ "$found" -eq 0 ] && NEW_DELETE+=("$sd")
        done
        DELETE=("''${NEW_DELETE[@]}")
      fi

      if [ "$GC_DAYS" -gt 0 ] && [ ''${#DELETE[@]} -gt 0 ]; then
        now_epoch=$(date +%s)
        declare -a AFTER_AGE=()
        for sd in "''${DELETE[@]}"; do
          ts=$(date -d "$sd" +%s 2>/dev/null) || continue
          age=$(( (now_epoch - ts) / 86400 ))
          [ "$age" -le "$GC_DAYS" ] && AFTER_AGE+=("$sd")
        done
        for sd in "''${AFTER_AGE[@]}"; do KEEP+=("$sd"); done
        declare -a FINAL_DELETE=()
        for sd in "''${DELETE[@]}"; do
          found=0
          for ad in "''${AFTER_AGE[@]}"; do
            [ "$sd" = "$ad" ] && { found=1; break; }
          done
          [ "$found" -eq 0 ] && FINAL_DELETE+=("$sd")
        done
        DELETE=("''${FINAL_DELETE[@]}")
      fi

      if [ "$_phase" != remove ] && [ ''${#SNAPSHOTS[@]} -gt 0 ]; then
        echo -e "${dimBlueString ".state/.cache snapshots"}"
        [ "$GC_GENS" -gt 0 ] && echo -e "Keeping ''${DIM_GREEN}$GC_GENS''${NC} snapshot generation(s)"
        [ "$GC_DAYS" -gt 0 ] && echo -e "Keeping snapshots newer than ''${DIM_GREEN}$GC_DAYS''${NC}d"
        if [ "$GC_GENS" -gt 0 ] || [ "$GC_DAYS" -gt 0 ]; then echo; fi
        for sd in "''${KEEP[@]}"; do
          echo -e "- ${dimGreenString "OK"} $CACHE_DIR/$sd"
        done
        for sd in "''${DELETE[@]}"; do
          if [ -n "$DRY" ]; then
            echo -e "- ${dimRedString "would DEL"} $CACHE_DIR/$sd"
          else
            echo -e "- ${dimRedString "DEL"} $CACHE_DIR/$sd"
          fi
        done
        echo
      fi

      if [ "$_phase" != preview ] && [ ''${#DELETE[@]} -gt 0 ]; then
        if [ -n "$DRY" ]; then
          total_kb=0
          for sd in "''${DELETE[@]}"; do
            skb=$(du -sk "$sd" 2>/dev/null | cut -f1)
            total_kb=$(( total_kb + ''${skb:-0} ))
          done
          total_mib=$(echo "scale=2; $total_kb / 1024" | ${bc})
          total_mib=$(printf "%.2f" "$total_mib")
          _summary_line="''${#DELETE[@]} snapshot path''$([ ''${#DELETE[@]} != 1 ] && echo s) would be deleted, ''${total_mib} MiB would be freed"
        else
          freed=0
          deleted=0
          for sd in "''${DELETE[@]}"; do
            echo -e "${dimGreenString ">"} Removing $CACHE_DIR/$sd"
            skb=$(du -sk "$sd" 2>/dev/null | cut -f1) || skb=0
            if rm -rf "$sd" 2>/dev/null; then
              deleted=$(( deleted + 1 ))
              freed=$(( freed + ''${skb:-0} ))
            else
              log_warn "failed to remove $sd"
            fi
          done
          freed_mib=$(echo "scale=2; $freed / 1024" | ${bc})
          freed_mib=$(printf "%.2f" "$freed_mib")
          _summary_line="$deleted snapshot path''$([ $deleted != 1 ] && echo s) deleted, ''${freed_mib} MiB freed"
        fi
        if [ -n "$_summary_file" ]; then
          echo "$_summary_line" > "$_summary_file"
        else
          echo "$_summary_line"
        fi
      fi
    ''}/bin/${command}";

  # Each hook entry → its own pkgs.writeShellScript so it runs in a
  # fresh shell process (isolated env/traps/`set -e`/`exit`). Prelude
  # prepended so hooks have color vars + log helpers, matching the
  # rebuild-hooks ergonomics. hookPaths returns a list (usable as
  # ExecStartPre/Post); runHooksAsUsers emits one runuser-wrapped
  # invocation per normal user for the timer service; gcHookRunBlock
  # wraps the same lines so `icedos gc` runs them per user from a
  # single sudo'd root context, keeping both paths identical.
  hookPaths =
    name: scripts:
    imap0 (i: s: writeShellScript "icedos-hook-${name}-${toString i}" "${prelude}\n${s}") scripts;

  # Hook execution identity. Hooks don't run as root by default: both the
  # `icedos gc` command and the automatic nh-clean.service run them once per
  # normal user (as that user) via runuser. The service is already root; the
  # `icedos gc` command self-elevates with sudo to switch users when needed.
  # A hook may also escalate itself with `sudo` where the user it runs as has
  # permission (e.g. NOPASSWD). A config with no normal users skips hooks in
  # both paths. The shared system steps of the service/command (nh clean,
  # temp-dir and config-history cleanup) stay root.
  normalUsers = map (u: u.name) (icedosLib.users.getNormal { inherit users; });

  runuser = "${pkgs.util-linux}/bin/runuser";
  coreutilsEnv = "${pkgs.coreutils}/bin/env";

  # `runuser -u` alone inherits the caller's environment (PATH, XDG_*,
  # DBUS_*, ...), leaking e.g. the invoking user's profile dirs into another
  # user's hooks. `runuser -l` is not an option: it is mutually exclusive
  # with `-u` in util-linux >= 2.42, and without /etc/login.defs (NixOS) its
  # login mode sets PATH to /usr/local/bin:/usr/bin:/bin. So pin the identity
  # and a NixOS login PATH explicitly via `env -i` — hooks then see the same
  # deterministic env from the timer (systemd) and from `icedos gc`
  # (sudo'd root), regardless of who invoked the command. Quote each whole
  # `NAME=value` item so it parses identically under bash and systemd
  # ExecStart (which only strips quotes wrapping a full item).
  loginEnv =
    user:
    let
      home =
        if (builtins.stringLength users.${user}.home != 0) then users.${user}.home else "/home/${user}";
      path = "/run/wrappers/bin:${home}/.nix-profile/bin:${home}/.local/state/nix/profile/bin:/etc/profiles/per-user/${user}/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin";
    in
    concatStringsSep " " [
      ''"HOME=${home}"''
      ''"USER=${user}"''
      ''"LOGNAME=${user}"''
      ''"PATH=${path}"''
    ];

  runHooksAsUsers =
    name: scripts:
    concatMap (
      u:
      map (h: "${runuser} -u \"${u}\" -- ${coreutilsEnv} -i ${loginEnv u} ${h}") (hookPaths name scripts)
    ) normalUsers;

  # The `icedos gc` command runs gc hooks per user just like the timer
  # service, but it isn't root — so instead of sudo-ing once per hook×user
  # pair, it elevates a single time (`sudo bash -c`) and runs every
  # per-user hook inside that one root context. Already root? Run the
  # lines directly. No hooks/users? Emit nothing. The `exit 0` appended to
  # the sudo payload keeps `|| die` firing only when elevation itself fails
  # (sudo auth/exec), never on a hook's exit status — hook failures are
  # then treated the same as in the already-root branch (no `set -e`).
  gcHookRunBlock =
    name: scripts:
    let
      runs = concatStringsSep "\n" (runHooksAsUsers name scripts);
    in
    if runs == "" then
      ""
    else
      ''
        if [ "$("${pkgs.coreutils}/bin/id" -u)" -eq 0 ]; then
          ${runs}
        else
          /run/wrappers/bin/sudo "${pkgs.bash}/bin/bash" -c ${
            escapeShellArg (runs + "\nexit 0")
          } || die "sudo failed; cannot run gc hooks per user"
        fi
      '';
in
{
  icedos.system.toolset.commands = [
    {
      command = "gc";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos gc [--dry|-n|--dry-run] [--days <N>] [--gens <N>]"
          echo "Clean the nix store, home-manager profiles, temp build dirs, and .state/.cache snapshots."
          echo
          echo "Options:"
          echo -e "  ${dimYellowString "--dry, -n, --dry-run"}: preview what would be deleted without actually cleaning"
          echo -e "  ${dimYellowString "--days, -d <N>"}: retention in days (store: ${toString gc.days}, snapshots: ${toString cache.days}; 0 = use --gens only)"
          echo -e "  ${dimYellowString "--gens, -g <N>"}: number of newest to keep (store: ${toString gc.generations}, snapshots: ${toString cache.generations}; 0 = aggressive)"
          exit 0
        fi

        DRY_RUN=""
        GC_DAYS="${toString gc.days}"
        GC_GENS="${toString gc.generations}"
        HAS_DAYS=0; HAS_GENS=0
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dry|--dry-run|-n)
              DRY_RUN="-n"
              shift
              ;;
            --days|-d)
              [ $# -ge 2 ] || die "--days value required"
              GC_DAYS="$2"; HAS_DAYS=1; shift 2
              ;;
            --gens|-g)
              [ $# -ge 2 ] || die "--gens value required"
              GC_GENS="$2"; HAS_GENS=1; shift 2
              ;;
            *)
              die "unknown arg: $1"
              ;;
          esac
        done

        [[ "$GC_DAYS" =~ ^[0-9]+$ ]] || die "--days must be a non-negative integer, got: $GC_DAYS"
        [[ "$GC_GENS" =~ ^[0-9]+$ ]] || die "--gens must be a non-negative integer, got: $GC_GENS"

        CACHE_ARGS=""
        [ "$HAS_DAYS" -eq 1 ] && CACHE_ARGS="$CACHE_ARGS --days $GC_DAYS"
        [ "$HAS_GENS" -eq 1 ] && CACHE_ARGS="$CACHE_ARGS --gens $GC_GENS"

        if [ -n "$DRY_RUN" ]; then
          log_step "dry run — no changes will be made"
        fi

        if [ -z "$DRY_RUN" ]; then
          :
          ${gcHookRunBlock "preGc" preGc}
        fi

        "${pkgs.nh}/bin/nh" clean all -k "$GC_GENS" -K "''${GC_DAYS}d" $DRY_RUN \
          || die "nh clean failed"

        echo
        if [ -z "$DRY_RUN" ]; then
          ${cleanExtra} --preview
          ${cacheCleanScript} $CACHE_ARGS --preview
          _summary_clean=$(mktemp) || die "mktemp failed"
          _summary_cache=$(mktemp) || die "mktemp failed"
          trap "rm -f '$_summary_clean' '$_summary_cache'" EXIT
          ${cleanExtra} --remove --summary-file "$_summary_clean"
          ${cacheCleanScript} $CACHE_ARGS --remove --summary-file "$_summary_cache"
          cat "$_summary_clean"
          cat "$_summary_cache"
          :
          ${gcHookRunBlock "postGc" postGc}
        else
          ${cleanExtra} -n
          ${cacheCleanScript} $CACHE_ARGS -n
          log_warn "dry run — nothing deleted; hooks skipped"
        fi
      '';

      help = "clean nix store, home-manager profiles, temp build dirs, and .state/.cache snapshots (--dry/-n/--dry-run for no-op preview; --days/--gens for retention override)";
    }
  ];

  programs.nh = {
    enable = true;

    clean = {
      enable = automatic;
      extraArgs = "-k ${generations} -K ${days}";
      dates = interval;
    };
  };

  systemd.services = mkIf automatic {
    nh-clean.serviceConfig = {
      ExecStartPre = runHooksAsUsers "preGc" preGc;
      ExecStartPost = [
        "-${cleanExtra}"
        "-${cacheCleanScript}"
      ]
      ++ runHooksAsUsers "postGc" postGc;
    };
  };
}
