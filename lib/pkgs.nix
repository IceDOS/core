{
  config,
  icedosLib,
  inputs,
  lib,
  self,
  ...
}:

let
  inherit (builtins)
    elem
    elemAt
    isAttrs
    length
    listToAttrs
    seq
    ;

  inherit (lib)
    concatStringsSep
    isDerivation
    splitString
    sublist
    ;

  inherit (icedosLib)
    _selectExtraFlakeOutput
    abortIf
    generateAttrPath
    ;

  extraFlakes = config.system.extra-flakes or [ ];
  extraFlakeNames = map (f: f.name) extraFlakes;

  resolvePackage =
    pkgs: pkgName:
    let
      parts = splitString "." pkgName;
    in
    if elemAt parts 0 == "icedosExtraFlakes" then
      let
        inherit (pkgs.stdenv.hostPlatform) system;
        lengthGuard =
          abortIf (length parts < 3)
            "icedos.system.extra-flakes: package string '${pkgName}' is missing package name (format: icedosExtraFlakes.<flake>.<package>)";
        flakeName = elemAt parts 1;
        nameGuard = seq lengthGuard (
          abortIf (!(elem flakeName extraFlakeNames))
            "icedos.system.extra-flakes: '${flakeName}' is not a configured extra-flake (add it to [[icedos.system.extra-flakes]])"
        );
        attrPath = sublist 2 (length parts - 2) parts;
        attrString = concatStringsSep "." attrPath;
        flake = inputs.${flakeName} or { };
        packages = flake.packages.${system} or null;
        legacyPackages = flake.legacyPackages.${system} or null;
        useLegacy =
          (packages == null || !lib.hasAttrByPath attrPath packages)
          && (legacyPackages != null && lib.hasAttrByPath attrPath legacyPackages);
        outputPath = "${if useLegacy then "legacyPackages" else "packages"}.${system}.${attrString}";
        selected = seq nameGuard (_selectExtraFlakeOutput flakeName outputPath inputs);
        drvGuard = abortIf (
          isAttrs selected && !isDerivation selected
        ) "icedos.system.extra-flakes: output '${outputPath}' on flake input '${flakeName}' is an attribute set, not a package";
      in
      seq drvGuard selected
    else
      generateAttrPath pkgs pkgName;
in
rec {
  pkgs = rec {
    mapper = pkgs: pkgList: map (resolvePackage pkgs) pkgList;

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
  };

}
