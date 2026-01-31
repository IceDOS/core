{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    attrNames
    mapAttrs
    foldl'
    splitString
    ;

  cfg = config.icedos;
in
{
  nix.settings.trusted-users = [
    "root"
  ]
  ++ (foldl' (acc: user: acc ++ [ user ]) [ ] (attrNames cfg.users));

  users.users = mapAttrs (
    user: _:
    let
      userAttrs = cfg.users.${user};
      homeDir = userAttrs.home;
      pkgMapper =
        pkgList: map (pkgName: foldl' (acc: cur: acc.${cur}) pkgs (splitString "." pkgName)) pkgList;
    in
    {
      description = "${userAttrs.description}";
      extraGroups = [ ] ++ lib.optional userAttrs.sudo "wheel" ++ userAttrs.extraGroups;
      home = if (builtins.stringLength homeDir != 0) then homeDir else "/home/${user}";
      isNormalUser = userAttrs.isNormalUser;
      isSystemUser = userAttrs.isSystemUser;
      password = userAttrs.defaultPassword;
      packages = [ ] ++ (pkgMapper cfg.users.${user}.extraPackages);
    }
  ) cfg.users;

  home-manager.users = mapAttrs (_: _: { home.stateVersion = cfg.system.version; }) cfg.users;
}
