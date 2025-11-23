{
  icedosLib,
  lib,
  ...
}:

let
  inherit (lib) fileContents;

  inherit (icedosLib)
    mkBoolOption
    mkNumberOption
    mkStrListOption
    mkStrOption
    mkSubmoduleListOption
    ;
in
{
  options = {
    icedos = {
      system = {
        arch = mkStrOption { };

        channels = mkSubmoduleListOption { default = [ ]; } {
          name = mkStrOption { };
          url = mkStrOption { };
        }; # e.g. https://github.com/NixOS/nixpkgs/branches/active

        forceFirstBuild = mkBoolOption { default = false; };
        isFirstBuild = mkBoolOption { default = false; };
        generations = mkNumberOption { default = 10; };
        version = mkStrOption { }; # Set according to docs at https://search.nixos.org/options?show=system.stateVersion
      };

      repositories = mkSubmoduleListOption { } {
        name = mkStrOption { };
        url = mkStrOption { };
        modules = mkStrListOption { };
      };
    };
  };

  config = fromTOML (fileContents ../config.toml);
}
