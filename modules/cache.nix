{ config, lib, ... }:

let
  inherit (lib) mkIf;
  inherit (config.icedos.system.cache) enable key url;
in
{
  nix.settings = mkIf enable {
    substituters = [ url ];
    trusted-public-keys = [ key ];
  };
}
