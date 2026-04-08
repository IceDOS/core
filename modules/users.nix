{
  config,
  lib,
  icedosLib,
  pkgs,
  ...
}:

let
  inherit (lib) attrNames mapAttrs;
  cfg = config.icedos;
in
{
  nix.settings.trusted-users = [
    "root"
  ]
  ++ (attrNames cfg.users);

  users.users = mapAttrs (
    user: _:
    let
      userAttrs = cfg.users.${user};
      homeDir = userAttrs.home;
    in
    {
      description = userAttrs.description;
      extraGroups = lib.optional userAttrs.sudo "wheel" ++ userAttrs.extraGroups;
      home = if (builtins.stringLength homeDir != 0) then homeDir else "/home/${user}";
      isNormalUser = userAttrs.isNormalUser;
      isSystemUser = userAttrs.isSystemUser;
      password = userAttrs.defaultPassword;
      packages = icedosLib.pkgMapper pkgs cfg.users.${user}.extraPackages;
    }
  ) cfg.users;

  home-manager.users = mapAttrs (_: _: {
    home.stateVersion = cfg.system.version;
    systemd.user.startServices = "sd-switch"; # Auto-restart user services whose unit files changed
  }) cfg.users;
}
