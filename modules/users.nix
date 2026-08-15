{
  config,
  lib,
  icedosLib,
  pkgs,
  ...
}:

let
  inherit (lib)
    attrNames
    concatLists
    filterAttrs
    mapAttrs
    mapAttrsToList
    optional
    ;

  inherit (config.icedos) system users;

  # Home dir, falling back to /home/<user> when unset.
  homeOf =
    user:
    let
      h = users.${user}.home;
    in
    if (builtins.stringLength h != 0) then h else "/home/${user}";
in
{
  # trusted-users grants unrestricted nix-daemon access; only opt-in users get it.
  nix.settings.trusted-users = [ "root" ] ++ attrNames (filterAttrs (_: u: u.trusted) users);

  users.users = mapAttrs (
    user: _:
    let
      userAttrs = users.${user};
      homeDir = userAttrs.home;
    in
    {
      description = userAttrs.description;
      extraGroups = optional userAttrs.sudo "wheel" ++ userAttrs.extraGroups;
      home = if (builtins.stringLength homeDir != 0) then homeDir else "/home/${user}";
      initialPassword = userAttrs.initialPassword;
      isNormalUser = userAttrs.isNormalUser;
      isSystemUser = userAttrs.isSystemUser;
      packages = icedosLib.pkgs.mapper pkgs users.${user}.packages;
    }
  ) users;

  # Rename pre-existing plain files to `<path>.hm-bak` instead of aborting activation.
  home-manager.backupFileExtension = "hm-bak";

  # home.packages into /etc/profiles/per-user/<user>, kept alive by the system
  # generation gcroot (nh clean would reap per-user nix-env profiles).
  home-manager.useUserPackages = true;

  # hm pkgs follow the system (allowUnfree, overlays); bare nixpkgs would miss them.
  home-manager.useGlobalPkgs = true;

  home-manager.users = mapAttrs (
    _: _:
    { lib, ... }:
    {
      home.stateVersion = system.version;
      systemd.user.startServices = "sd-switch"; # Auto-restart user services whose unit files changed

      # Sweep stale .hm-bak files before HM's collision check (checkLinkTargets),
      # which would otherwise abort on an already-existing backup.
      home.activation.cleanHmBackups = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
        run ${pkgs.findutils}/bin/find "$HOME" -maxdepth 8 -name '*.hm-bak' -type f -delete || true
      '';
    }
  ) users;

  # Seed per-user dirs HM needs on first boot (fresh VMs never log in to create
  # them); tmpfiles `d` doesn't recurse, so every path level is listed.
  systemd.tmpfiles.rules = concatLists (
    mapAttrsToList (
      user: _:
      let
        home = homeOf user;
        own = "${user} users";
      in
      [
        "d /nix/var/nix/profiles/per-user/${user} 0755 ${own} -"
        "d ${home}/.local                              0755 ${own} -"
        "d ${home}/.local/share                        0755 ${own} -"
        "d ${home}/.local/state                        0755 ${own} -"
        "d ${home}/.local/state/nix                    0755 ${own} -"
        "d ${home}/.local/state/nix/profiles           0755 ${own} -"
        "d ${home}/.local/state/home-manager           0755 ${own} -"
        "d ${home}/.local/state/home-manager/gcroots   0755 ${own} -"
      ]
    ) users
  );
}
