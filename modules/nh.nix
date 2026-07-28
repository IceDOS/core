{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash)
    dimBlueString
    dimGreenString
    dimRedString
    dimYellowString
    genHelpFlags
    prelude
    ;

  inherit (lib)
    concatStringsSep
    imap0
    mkIf
    ;

  inherit (pkgs) writeShellScript writeShellScriptBin;

  inherit (config.icedos.system) gc;
  inherit (gc) automatic hooks interval;
  inherit (hooks) postGc preGc;

  days = "${toString gc.days}d";
  generations = toString gc.generations;

  cleanExtra =
    let
      bc = "${pkgs.bc}/bin/bc";
      command = "nh-clean-extra";
    in
    "${writeShellScriptBin command ''
      ${prelude}

      echo -e "\n${dimBlueString "/tmp/nix-shell-*/icedos-build"}"

      tempBuildDirs=$(find /tmp -type d -name "icedos-build*" 2>/dev/null)
      totalSize=0
      buildPathsCount=0

      for dir in $tempBuildDirs; do
          echo -e "- ${dimRedString "DEL"} $dir"
          sizeKb=$(du -sk "$dir" | cut -f1)
          sizeMb=$(echo "scale=2; $sizeKb / 1024" | ${bc})
          totalSize=$(echo "scale=2; $totalSize + $sizeMb" | ${bc})
          buildPathsCount=$(( buildPathsCount + 1 ))
      done

      formattedTotal=$(printf "%.2f" "$totalSize")

      echo -e

      for dir in $tempBuildDirs; do
          echo -e "${dimGreenString ">"} Removing $dir"
          rm -r "$dir"
      done

      echo -e "\n''$buildPathsCount build path''$([ $buildPathsCount != 1 ] && echo s) deleted, ''${formattedTotal} MiB freed"
    ''}/bin/${command}";

  # Each hook entry → its own pkgs.writeShellScript so it runs in a
  # fresh shell process (isolated env/traps/`set -e`/`exit`). Prelude
  # prepended so hooks have color vars + log helpers, matching the
  # rebuild-hooks ergonomics. hookPaths returns a list (usable as
  # ExecStartPre/Post); runHooks joins paths with newlines (usable
  # inside the toolset bash script).
  hookPaths =
    name: scripts:
    imap0 (i: s: writeShellScript "icedos-hook-${name}-${toString i}" "${prelude}\n${s}") scripts;

  runHooks = name: scripts: concatStringsSep "\n" (map toString (hookPaths name scripts));
in
{
  icedos.system.toolset.commands = [
    {
      command = "gc";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos gc [--dry|-n|--dry-run]"
          echo "Clean the nix store, home-manager profiles, and temp build dirs."
          echo
          echo "Options:"
          echo -e "  ${dimYellowString "--dry, -n, --dry-run"}: preview what would be deleted without actually cleaning"
          exit 0
        fi

        DRY_RUN=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dry|--dry-run|-n)
              DRY_RUN="-n"
              shift
              ;;
            *)
              die "unknown arg: $1"
              ;;
          esac
        done

        if [ -n "$DRY_RUN" ]; then
          log_step "dry run — no changes will be made"
        fi

        if [ -z "$DRY_RUN" ]; then
          :
          ${runHooks "preGc" preGc}
        fi

        "${pkgs.nh}/bin/nh" clean all -k "${generations}" -K "${days}" $DRY_RUN \
          || die "nh clean failed"

        if [ -z "$DRY_RUN" ]; then
          ${cleanExtra}
          :
          ${runHooks "postGc" postGc}
        else
          echo
          log_warn "dry run — preGc hooks, cleanExtra (temp build dirs), and postGc hooks skipped"
        fi
      '';

      help = "clean nix store, home-manager profiles, and temp build dirs (--dry/-n/--dry-run for no-op preview)";
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

  systemd.services.nh-clean.serviceConfig = mkIf automatic {
    ExecStartPre = [ cleanExtra ] ++ map toString (hookPaths "preGc" preGc);
    ExecStartPost = map toString (hookPaths "postGc" postGc);
  };
}
