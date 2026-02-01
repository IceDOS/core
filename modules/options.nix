{
  icedosLib,
  inputs,
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
    mkSubmoduleAttrsOption
    mkSubmoduleListOption
    ;
in
{
  options = {
    icedos = {
      system = {
        arch = mkStrOption { default = "x86_64-linux"; };

        channels = mkSubmoduleListOption { default = [ ]; } {
          name = mkStrOption { };
          url = mkStrOption { };
        }; # e.g. https://github.com/NixOS/nixpkgs/branches/active

        forceFirstBuild = mkBoolOption { default = false; };
        isFirstBuild = mkBoolOption { default = false; };
        generations = mkNumberOption { default = 10; };
        version = mkStrOption { }; # Set according to docs at https://search.nixos.org/options?show=system.stateVersion
      };

      repositories = mkSubmoduleListOption { default = [ ]; } {
        url = mkStrOption { };
        overrideUrl = mkStrOption { default = ""; };
        fetchOptionalDependencies = mkBoolOption { default = false; };
        modules = mkStrListOption { default = [ ]; };
      };

      users = mkSubmoduleAttrsOption { } {
        defaultPassword = mkStrOption { default = "1"; };
        description = mkStrOption { default = ""; };
        extraGroups = mkStrListOption { default = [ ]; };
        extraPackages = mkStrListOption { default = [ ]; };
        home = mkStrOption { default = ""; };
        isNormalUser = mkBoolOption { default = true; };
        isSystemUser = mkBoolOption { default = false; };
        sudo = mkBoolOption { default = true; };
      };
    };
  };

  config = fromTOML (fileContents "${inputs.icedos-config}/config.toml");
}
