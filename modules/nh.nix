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
    dimYellowString
    gcLib
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

  flock = "${pkgs.util-linux}/bin/flock";

  inherit (config.icedos.system) gc;
  inherit (gc)
    automatic
    cache
    hooks
    interval
    ;
  inherit (hooks)
    postGc
    preGc
    rootPostGc
    rootPreGc
    ;
  inherit (config.icedos) users;

  days = "${toString gc.days}d";
  generations = toString gc.generations;

  cleanExtra =
    let
      command = "nh-clean-extra";
    in
    "${writeShellScriptBin command ''
      ${prelude}
      ${gcLib}

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --preview|-p) export ICEDOS_GC_PHASE=preview; shift ;;
          --remove|-r)  export ICEDOS_GC_PHASE=remove; shift ;;
          --summary-file) [ $# -ge 2 ] || die "--summary-file value required"; export ICEDOS_GC_SUMMARY_FILE="$2"; shift 2 ;;
          -n|--dry-run) export ICEDOS_GC_DRY=1; shift ;;
          *) die "nh-clean-extra: unknown arg: $1" ;;
        esac
      done

      # Newest first, like nh's generation lists.
      declare -a tempBuildDirs=()
      while IFS= read -r -d $'\0' entry; do
        tempBuildDirs+=("''${entry#* }")
      done < <(find /tmp -type d -name 'icedos-build*' -printf '%T@ %p\0' 2>/dev/null | sort -z -rn)

      # A live build holds a flock on `.lock` (released on exit/crash), so only
      # live dirs are skipped; unreadable ones are another user's.
      declare -a buildDirs=()
      declare -a inFlightDirs=()
      for dir in "''${tempBuildDirs[@]}"; do
        if [ ! -r "$dir" ] || [ ! -x "$dir" ] || { [ -e "$dir/.lock" ] && ! ${flock} -n "$dir/.lock" true 2>/dev/null; }; then
          inFlightDirs+=("$dir")
        else
          buildDirs+=("$dir")
        fi
      done

      gc_section "/tmp/icedos-build*" "build path"

      for dir in "''${buildDirs[@]}"; do
        gc_del "$dir"
      done
      for dir in "''${inFlightDirs[@]}"; do
        gc_skip "$dir" "build in flight or not ours"
      done
      exit 0
    ''}/bin/${command}";

  cacheCleanScript =
    let
      command = "nh-cache-clean";
    in
    "${writeShellScriptBin command ''
      ${prelude}
      ${gcLib}

      GC_DAYS=${toString cache.days}
      GC_GENS=${toString cache.generations}

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --days|-d) [ $# -ge 2 ] || die "cacheClean: --days value required"; GC_DAYS="$2"; shift 2 ;;
          --gens|-g) [ $# -ge 2 ] || die "cacheClean: --gens value required"; GC_GENS="$2"; shift 2 ;;
          --preview|-p) export ICEDOS_GC_PHASE=preview; shift ;;
          --remove|-r)  export ICEDOS_GC_PHASE=remove; shift ;;
          --summary-file) [ $# -ge 2 ] || die "cacheClean: --summary-file value required"; export ICEDOS_GC_SUMMARY_FILE="$2"; shift 2 ;;
          -n|--dry-run) export ICEDOS_GC_DRY=1; shift ;;
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

      # Snapshot names carry differing UTC offsets, so sort by epoch, newest first.
      sortByTsDesc() {
        local -n _arr=$1
        local sd ts
        local -a lines=()
        for sd in "''${_arr[@]}"; do
          ts=$(date -d "$sd" +%s 2>/dev/null) || ts=0
          lines+=("$ts|$sd")
        done
        _arr=()
        while IFS= read -r line; do
          [ -n "$line" ] && _arr+=("''${line#*|}")
        done < <(printf '%s\n' "''${lines[@]}" | sort -t'|' -k1,1nr)
      }
      sortByTsDesc KEEP
      sortByTsDesc DELETE

      gc_section "$CACHE_DIR" "snapshot path"
      [ "$GC_GENS" -gt 0 ] && gc_note "Keeping ''${DIM_GREEN}$GC_GENS''${NC} snapshot generation(s)"
      [ "$GC_DAYS" -gt 0 ] && gc_note "Keeping snapshots newer than ''${DIM_GREEN}$GC_DAYS''${NC}d"

      for sd in "''${KEEP[@]}"; do
        gc_ok "$CACHE_DIR/$sd"
      done
      for sd in "''${DELETE[@]}"; do
        gc_del "$CACHE_DIR/$sd"
      done
      exit 0
    ''}/bin/${command}";

  # One script per hook, so each runs in a fresh shell (isolated env/traps/exit)
  # with the prelude and gcLib available.
  hookPaths =
    name: scripts:
    imap0 (
      i: s: writeShellScript "icedos-hook-${name}-${toString i}" "${prelude}\n${gcLib}\n${s}"
    ) scripts;

  # Hooks run once per normal user AS that user (never root by default); the
  # shared system steps stay root.
  normalUsers = map (u: u.name) (icedosLib.users.getNormal { inherit users; });

  runuser = "${pkgs.util-linux}/bin/runuser";
  coreutilsEnv = "${pkgs.coreutils}/bin/env";

  # `runuser -u` would leak the caller's env and `-l` is unusable here, so pin the
  # identity and a login PATH via `env -i`, quoting each whole `NAME=value` item.
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

  # Same runs for `icedos gc`, but each hook gets its own user-owned file in the
  # totals dir ($1) where gc.sh records the KiB it freed.
  runHooksWithTotals =
    name: scripts:
    concatMap (
      u:
      imap0 (
        i: h:
        let
          file = ''"$_gc_tot/${name}-${u}-${toString i}"'';
        in
        concatStringsSep "\n" [
          "${pkgs.coreutils}/bin/install -m 644 -o \"${u}\" /dev/null ${file} 2>/dev/null || true"
          "${runuser} -u \"${u}\" -- ${coreutilsEnv} -i ${loginEnv u} \"ICEDOS_GC_TOTAL_FILE=$_gc_tot/${name}-${u}-${toString i}\" ${h}"
        ]
      ) (hookPaths name scripts)
    ) normalUsers;

  # Root hooks run once as root, from the same minimal env as the per-user ones.
  rootEnv = concatStringsSep " " [
    ''"HOME=/root"''
    ''"USER=root"''
    ''"LOGNAME=root"''
    ''"PATH=/run/wrappers/bin:/run/current-system/sw/bin"''
  ];

  runHooksAsRoot =
    name: scripts: map (h: "${coreutilsEnv} -i ${rootEnv} ${h}") (hookPaths name scripts);

  runRootHooksWithTotals =
    name: scripts:
    imap0 (
      i: h:
      let
        file = "$_gc_tot/${name}-root-${toString i}";
      in
      concatStringsSep "\n" [
        "${pkgs.coreutils}/bin/install -m 644 /dev/null \"${file}\" 2>/dev/null || true"
        "${coreutilsEnv} -i ${rootEnv} \"ICEDOS_GC_TOTAL_FILE=${file}\" ${h}"
      ]
    ) (hookPaths name scripts);

  # `icedos gc` elevates once and runs every per-user and root hook in that root
  # context. The trailing `exit 0` keeps `|| die` firing on elevation failure only.
  gcHookRunBlock =
    hookRuns:
    let
      runs = concatStringsSep "\n" hookRuns;
      script = escapeShellArg ("_gc_tot=\"$1\"\n" + runs + "\nexit 0");
    in
    if runs == "" then
      ""
    else
      ''
        if [ "$("${pkgs.coreutils}/bin/id" -u)" -eq 0 ]; then
          "${pkgs.bash}/bin/bash" -c ${script} _ "$_gc_tot"
        else
          /run/wrappers/bin/sudo "${pkgs.bash}/bin/bash" -c ${script} _ "$_gc_tot" \
            || die "sudo failed; cannot run gc hooks"
        fi
      '';
in
{
  icedos.system.toolset.commands = [
    {
      command = "gc";

      script = ''
        ${gcLib}

        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos gc [--dry|-n|--dry-run] [--days <N>] [--gens <N>]"
          echo "Clean the nix store, home-manager profiles, temp build dirs, and .state/.cache snapshots, then run gc hooks."
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
          log_step "dry run, no changes will be made"
        fi

        # Every section writes the KiB it freed here; hooks run as other users, so
        # the dir is traversable (711) and each hook gets its own pre-owned file.
        _gc_tot=$(mktemp -d) || die "mktemp failed"
        chmod 711 "$_gc_tot"
        trap "rm -rf '$_gc_tot'; command -v _icedos_tip >/dev/null 2>&1 && _icedos_tip" EXIT

        if [ -z "$DRY_RUN" ]; then
          :
          ${gcHookRunBlock (
            runHooksWithTotals "preGc" preGc ++ runRootHooksWithTotals "rootPreGc" rootPreGc
          )}
        fi

        # Log nh's output to read the store-GC "freed" line; `script` keeps a pty so
        # colours and nh's sudo prompt still work (it logs output only, not keystrokes).
        _nh_log="$_gc_tot/nh.log"
        : > "$_nh_log" && chmod 600 "$_nh_log"
        _nh_cmd=("${pkgs.nh}/bin/nh" clean all -k "$GC_GENS" -K "''${GC_DAYS}d" $DRY_RUN)
        if [ -t 1 ]; then
          SHELL="${pkgs.bash}/bin/bash" "${pkgs.util-linux}/bin/script" -qefc "$(printf '%q ' "''${_nh_cmd[@]}")" "$_nh_log" \
            || die "nh clean failed"
        else
          "''${_nh_cmd[@]}" 2>&1 | "${pkgs.coreutils}/bin/tee" "$_nh_log"
          [ "''${PIPESTATUS[0]}" -eq 0 ] || die "nh clean failed"
        fi

        if [ -z "$DRY_RUN" ]; then
          : > "$_gc_tot/core"
          export ICEDOS_GC_TOTAL_FILE="$_gc_tot/core"
          ${cleanExtra} --preview
          ${cacheCleanScript} $CACHE_ARGS --preview
          _summary_clean="$_gc_tot/summary-clean.log"
          _summary_cache="$_gc_tot/summary-cache.log"
          ${cleanExtra} --remove --summary-file "$_summary_clean"
          ${cacheCleanScript} $CACHE_ARGS --remove --summary-file "$_summary_cache"
          [ -f "$_summary_clean" ] && cat "$_summary_clean"
          [ -f "$_summary_cache" ] && cat "$_summary_cache"
          unset ICEDOS_GC_TOTAL_FILE
          :
          ${gcHookRunBlock (
            runHooksWithTotals "postGc" postGc ++ runRootHooksWithTotals "rootPostGc" rootPostGc
          )}
          gc_print_total "$_gc_tot" "$(gc_parse_freed_kb "$_nh_log")"
        else
          ${cleanExtra} -n
          ${cacheCleanScript} $CACHE_ARGS -n
          log_warn "dry run: nothing deleted, hooks skipped"
        fi
      '';

      help = "clean nix store, home-manager profiles, temp build dirs, and .state/.cache snapshots, then run gc hooks (--dry/-n/--dry-run for no-op preview; --days/--gens for retention override)";
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
      ExecStartPre = runHooksAsUsers "preGc" preGc ++ runHooksAsRoot "rootPreGc" rootPreGc;
      ExecStartPost = [
        "-${cleanExtra}"
        "-${cacheCleanScript}"
      ]
      ++ runHooksAsUsers "postGc" postGc
      ++ runHooksAsRoot "rootPostGc" rootPostGc;
    };
  };

  icedos.system.tips.list = [
    "icedos gc frees disk space by removing old system versions and junk."
  ];
}
