{
  icedosLib,
  lib,
  self,
  ...
}:

let
  inherit (builtins) listToAttrs;

  inherit (icedosLib) generateAttrPath;
in
rec {
  pkgs = rec {
    mapper = pkgs: pkgList: map (pkgName: generateAttrPath pkgs pkgName) pkgList;

    # The one nixpkgs `config` every consumer routes through. Hardware keys
    # (cudaSupport, …) are written per-key by hardware modules and merge in.
    mkConfig = icedos: {
      inherit (icedos.system)
        allowUnfree
        permittedInsecurePackages
        ;
    };

    # Overlay lifting named packages from a channel name (looked up on `super`) or
    # a flake input (instantiated with `mkConfig`; the host config would crash it).
    overlaysFromChannel = icedos: channel: packages: [
      (
        self: super:
        let
          channelPkgs =
            if channel ? outPath then
              import channel {
                inherit (super.stdenv.hostPlatform) system;
                config = mkConfig icedos;
              }
            else
              super.${channel};
        in
        listToAttrs (
          map (package: {
            name = package;
            value = generateAttrPath channelPkgs package;
          }) packages
        )
      )
    ];

    # Overlay exposing the packages of each extra-flake under `icedosExtraFlakes.<flake>.<pkg>`.
    icedosExtraFlakes =
      {
        extraFlakes ? [ ],
        inputs ? { },
      }:
      final: prev: {
        icedosExtraFlakes = listToAttrs (
          map (f: {
            name = f.name;
            value =
              let
                flake = inputs.${f.name} or { };
                system = prev.stdenv.hostPlatform.system or prev.system;
              in
              (flake.legacyPackages.${system} or { }) // (flake.packages.${system} or { });
          }) extraFlakes
        );
      };
  };

}
