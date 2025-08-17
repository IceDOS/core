{ lib, pkgs, ... }:
let
  inherit (lib) mkIf;
in
mkIf false {
  environment.systemPackages = [ pkgs.vesktop ];
}
