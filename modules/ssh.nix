{ config, lib, ... }:

let
  inherit (lib) mkIf optionals;
  inherit (config.icedos.system) ssh;
in
{
  services.openssh.enable = mkIf ssh true;
  programs.zsh.shellAliases.ssh = mkIf ssh "TERM=xterm-256color ssh";

  icedos.system.tips.list = optionals ssh [
    "SSH is on, so you can reach this machine from another computer."
  ];
}
