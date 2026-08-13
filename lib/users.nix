{
  icedosLib,
  lib,
  self,
  ...
}:

let
  inherit (lib)
    filterAttrs
    mapAttrs
    mapAttrsToList
    ;
in
rec {
  # The accent map / `desktop` / `systemd` namespaces live in the desktop repo's
  # `lib.nix` (contributed via its `default` module): they are DE-dependent.
  users = {
    getNormal =
      { users }:
      mapAttrsToList (name: attrs: {
        inherit name;
        value = attrs;
      }) (filterAttrs (n: v: v.isNormalUser) users);

    # Per-normal-user attrset, so submodule defaults materialise without the user
    # writing an empty `[icedos.<path>.users.<name>]` stanza each time.
    genDefaults =
      {
        users,
        value ? { },
      }:
      mapAttrs (_: _: value) (filterAttrs (_: v: v.isNormalUser) users);

    mkGroupInjector = group: users: mapAttrs (_: _: { extraGroups = [ group ]; }) users;
  };

}
