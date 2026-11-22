{
  config,
  inputs,
  lib,
  ...
}:

let
  inherit (builtins) pathExists;
  inherit (lib)
    any
    head
    importJSON
    mkIf
    optional
    optionals
    splitString
    ;

  inherit (config.icedos.system.cache)
    enable
    key
    priority
    url
    ;

  icedos-state = inputs.icedos-state or null;

  registered =
    if icedos-state != null && pathExists "${icedos-state}/substituters" then
      importJSON "${icedos-state}/substituters"
    else
      [ ];

  stripQuery = s: head (splitString "?" s);
  cleanUrl = stripQuery url;
  isRegistered = any (sub: (stripQuery sub) == cleanUrl) registered;

  pending = enable && !isRegistered;
in
{
  icedos.system.cache.pending = pending;

  nix.settings = mkIf enable {
    substituters = [ "${url}?priority=${toString priority}" ];
    trusted-public-keys = [ key ];
  };

  warnings = optional pending ''
    cache: the IceDOS binary cache is not yet in /etc/icedos/substituters.
    Heavy modules are skipped or fall back this generation; run 'icedos rebuild' again after activation.
  '';

  icedos.system.tips.list =
    optionals enable [
      "The binary cache downloads prebuilt custom and unfree packages, so rebuilds compile less."
    ]
    ++ optional pending "The binary cache needs two rebuilds: the first sets up its download server, the second installs from it.";
}
