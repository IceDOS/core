{ config, lib, ... }:

let
  inherit (lib) mkIf optionals;

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

  icedos.system.tips.list = optionals enable [
    "The binary cache downloads prebuilt custom and unfree packages, so rebuilds compile less."
  ];
}
