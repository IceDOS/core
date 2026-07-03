{ config, lib, ... }:

let
  inherit (lib) mkIf;
  inherit (config.icedos) system;
  inherit (system.bootloaders.systemd-boot) enable mountPoint;
  inherit (system) generations;
in
{
  boot.loader = mkIf enable {
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = mountPoint;
    };

    systemd-boot = {
      enable = true;
      configurationLimit = generations;
      consoleMode = "max";
    };

    timeout = 1;
  };
}
