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
    mapAttrs
    mapAttrsToList
    optional
    ;
  inherit (config.icedos) system users;

  # Resolve home dir the same way `users.users` below does — fall back to
  # `/home/<user>` when `userAttrs.home` is unset.
  homeOf =
    user:
    let
      h = users.${user}.home;
    in
    if (builtins.stringLength h != 0) then h else "/home/${user}";
in
{
  nix.settings.trusted-users = [
    "root"
  ]
  ++ (attrNames users);

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
      isNormalUser = userAttrs.isNormalUser;
      isSystemUser = userAttrs.isSystemUser;
      password = userAttrs.defaultPassword;
      packages = icedosLib.pkgs.mapper pkgs users.${user}.packages;
    }
  ) users;

  # Rename pre-existing plain files to `<path>.hm-bak` instead of aborting activation.
  home-manager.backupFileExtension = "hm-bak";

  # Install home-manager `home.packages` into `/etc/profiles/per-user/<user>` (via
  # `users.users.<name>.packages`) rather than a per-user `nix-env` profile. The former
  # rides the system-generation gcroot (`/nix/var/nix/gcroots/current-system`); the latter
  # is rooted only by `/nix/var/nix/gcroots/per-user/<user>`, which `nh clean` (>=4.4.0)
  # deletes as "orphaned" — unrooting the live profile so GC reaps it (kitty/walker vanish).
  home-manager.useUserPackages = true;

  home-manager.users = mapAttrs (
    _: _:
    { lib, ... }:
    {
      home.stateVersion = system.version;
      systemd.user.startServices = "sd-switch"; # Auto-restart user services whose unit files changed

      # `backupFileExtension = "hm-bak"` (above) makes HM rename conflicting
      # plain files to `<path>.hm-bak`. With a fixed extension, a second
      # rebuild that produces a *new* conflict on the same path aborts at
      # the rename step with "file exists" because the prior `.hm-bak` is
      # still there. Sweep stale backups *before* the writeBoundary phase
      # (where HM performs the rename) so each activation finds an empty
      # backup namespace.
      home.activation.cleanHmBackups = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
        run ${pkgs.findutils}/bin/find "$HOME" -maxdepth 8 -name '*.hm-bak' -type f -delete || true
      '';
    }
  ) users;

  # Pre-create per-user dirs that home-manager-<user>.service expects on first
  # boot. nix-daemon creates `/nix/var/nix/profiles/per-user/<user>` lazily on
  # the user's first nix invocation, and HM activation then writes
  # `~/.local/state/home-manager/gcroots/new-home` via `nix-store --add-root`,
  # which won't auto-create intermediate parents. In fresh VMs / headless boxes
  # the user never logs in to seed those dirs, so HM activation fails with
  # "Permission denied" or "Could not find suitable profile directory". tmpfiles
  # `d` doesn't recurse into parents, so each path level is listed explicitly.
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
