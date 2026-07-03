{ config, lib, ... }:

let
  inherit (lib) mkIf;
  inherit (config.icedos.system) ssh;
in
{
  services.openssh.enable = mkIf ssh true;
  programs.zsh.shellAliases.ssh = mkIf ssh "TERM=xterm-256color ssh";
}
