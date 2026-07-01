{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash)
    prelude
    dimBlueString
    dimGreenString
    dimRedString
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
        ${runHooks "preGc" preGc}
        "${pkgs.nh}/bin/nh" clean all -k "${generations}" -K "${days}" && ${cleanExtra}
        ${runHooks "postGc" postGc}
      '';

      help = "clean nix plus home manager, store and profiles";
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
