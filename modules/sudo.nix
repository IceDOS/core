{ config, lib, ... }:

let
  inherit (lib) mkIf;
  inherit (config.icedos.system.sudo) passwordFeedback rs;

  pwfeedback = mkIf passwordFeedback "Defaults pwfeedback"; # Show asterisks when typing sudo password
in
{
  security.sudo.extraConfig = pwfeedback;

  security.sudo-rs = mkIf rs {
    enable = true;
    execWheelOnly = true;
    extraConfig = pwfeedback;
  };
}
