{ config, lib, ... }:

let
  inherit (lib) mkIf;
  inherit (config.icedos) system;
  inherit (system.bootloaders.grub) device enable;
  inherit (system) generations;
in
{
  boot = mkIf enable {
    loader = {
      grub = {
        inherit device;
        enable = true;
        useOSProber = true;
        enableCryptodisk = true;
        configurationLimit = generations;
      };

      timeout = 1;
    };

    initrd.secrets = {
      "/crypto_keyfile.bin" = null;
    };
  };
}
