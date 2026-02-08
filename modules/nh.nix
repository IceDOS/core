{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.icedos.applications.nh.gc;
  command = "gc";
  days = "${toString (cfg.days)}d";
  generations = toString (cfg.generations);

  cleanExtra =
    let
      bc = "${pkgs.bc}/bin/bc";
      command = "nh-clean-extra";
    in
    "${pkgs.writeShellScriptBin command ''
      BLUE='\e[34m'
      GREEN='\033[0;32m'
      RED='\033[0;31m'
      NC='\033[0m'


      echo -e "\n''${BLUE}/tmp/nix-shell-*/icedos-build''${NC}"

      tempBuildDirs=$(find /tmp -type d -name "icedos-build*" 2>/dev/null)
      totalSize=0
      buildPathsCount=0

      for dir in $tempBuildDirs; do
          echo -e "- ''${RED}DEL''${NC} $dir"
          sizeKb=$(du -sk "$dir" | cut -f1)
          sizeMb=$(echo "scale=2; $sizeKb / 1024" | ${bc})
          totalSize=$(echo "scale=2; $totalSize + $sizeMb" | ${bc})
          buildPathsCount=$(( buildPathsCount + 1 ))
      done

      formattedTotal=$(printf "%.2f" "$totalSize")

      echo -e

      for dir in $tempBuildDirs; do
          echo -e "''${GREEN}>''${NC} Removing $dir"
          rm -r "$dir"
      done

      echo -e "\n''$buildPathsCount build path''$([ $buildPathsCount != 1 ] && echo s) deleted, ''${formattedTotal} MiB freed"
    ''}/bin/${command}";
in
{
  icedos.applications.toolset.commands = [
    {
      bin = "${pkgs.writeShellScript command ''"${pkgs.nh}/bin/nh" clean all -k "${generations}" -K "${days}" && ${cleanExtra}''}";
      command = command;
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

  systemd.services.nh-clean.serviceConfig.ExecStartPost = lib.mkIf cfg.automatic cleanExtra;
}
