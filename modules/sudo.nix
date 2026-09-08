{ config, lib, ... }:

let
  inherit (lib) mkIf optionals;
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

  icedos.system.tips.list = optionals passwordFeedback [
    "Most, if not all, password prompts will show asterisks as you type."
  ];
}
