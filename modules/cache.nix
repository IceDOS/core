{ config, lib, ... }:

let
  inherit (lib) mkIf;

  inherit (config.icedos.system.cache)
    enable
    key
    url
    priority
    ;
in
{
  nix.settings = mkIf enable {
    substituters = [ "${url}?priority=${toString priority}" ];
    trusted-public-keys = [ key ];
  };
}
