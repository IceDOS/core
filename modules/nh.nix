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

  inherit (lib) mkIf;

  cfg = config.icedos.applications.nh.gc;
  days = "${toString (cfg.days)}d";
  generations = toString (cfg.generations);

  cleanExtra =
    let
      bc = "${pkgs.bc}/bin/bc";
      command = "nh-clean-extra";
    in
    "${pkgs.writeShellScriptBin command ''
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

  hooks = config.icedos.applications.nh.gc.hooks;

  # Each hook entry → its own pkgs.writeShellScript so it runs in a
  # fresh shell process (isolated env/traps/`set -e`/`exit`). Prelude
  # prepended so hooks have color vars + log helpers, matching the
  # rebuild-hooks ergonomics. hookPaths returns a list (usable as
  # ExecStartPre/Post); runHooks joins paths with newlines (usable
  # inside the toolset bash script).
  hookPaths =
    name: scripts:
    lib.imap0 (
      i: s: pkgs.writeShellScript "icedos-hook-${name}-${toString i}" "${prelude}\n${s}"
    ) scripts;

  runHooks = name: scripts: lib.concatStringsSep "\n" (map toString (hookPaths name scripts));
in
{
  icedos.applications.toolset.commands = [
    {
      command = "gc";

      script = ''
        ${runHooks "preGc" hooks.preGc}
        "${pkgs.nh}/bin/nh" clean all -k "${generations}" -K "${days}" && ${cleanExtra}
        ${runHooks "postGc" hooks.postGc}
      '';

      help = "clean nix plus home manager, store and profiles";
    }
  ];

  programs.nh = {
    enable = true;

    clean = {
      enable = cfg.automatic;
      extraArgs = "-k ${toString (cfg.generations)} -K ${days}";
      dates = cfg.interval;
    };
  };

  systemd.services.nh-clean.serviceConfig = mkIf cfg.automatic {
    ExecStartPre = [ cleanExtra ] ++ map toString (hookPaths "preGc" hooks.preGc);
    ExecStartPost = map toString (hookPaths "postGc" hooks.postGc);
  };
}
