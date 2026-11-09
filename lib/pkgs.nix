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
    head
    length
    listToAttrs
    seq
    ;

  inherit (lib)
    concatStringsSep
    drop
    getAttrFromPath
    hasAttrByPath
    isDerivation
    splitString
    ;

  inherit (icedosLib)
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
    if head parts == "icedosExtraFlakes" then
      let
        systemGuard = abortIf (
          !(pkgs ? stdenv.hostPlatform.system) && !(config ? system.arch)
        ) "icedos.system.extra-flakes: cannot determine system architecture";
        system = seq systemGuard (pkgs.stdenv.hostPlatform.system or config.system.arch);
        lengthGuard =
          abortIf (length parts < 3)
            "icedos.system.extra-flakes: package string '${pkgName}' is missing package name (format: icedosExtraFlakes.<flake>.<package>)";
        flakeName = elemAt parts 1;
        nameGuard = seq lengthGuard (
          abortIf (!(elem flakeName extraFlakeNames))
            "icedos.system.extra-flakes: '${flakeName}' is not a configured extra-flake (add it to [[icedos.system.extra-flakes]])"
        );
        inputGuard = seq nameGuard (
          abortIf (!(inputs ? ${flakeName}))
            "icedos.system.extra-flakes: input '${flakeName}' is not present in the flake inputs (registered as a top-level input via `name`)"
        );
        attrPath = drop 2 parts;
        attrString = concatStringsSep "." attrPath;
        flake = inputs.${flakeName} or { };
        packages = flake.packages.${system} or { };
        legacyPackages = flake.legacyPackages.${system} or { };
        hasPackages = hasAttrByPath attrPath packages;
        hasLegacy = hasAttrByPath attrPath legacyPackages;
        notFoundGuard =
          abortIf (!hasPackages && !hasLegacy)
            "icedos.system.extra-flakes: output 'packages.${system}.${attrString}' or 'legacyPackages.${system}.${attrString}' on flake input '${flakeName}' not found";
        useLegacy = !hasPackages && hasLegacy;
        outputPath = "${if useLegacy then "legacyPackages" else "packages"}.${system}.${attrString}";
        selected = seq inputGuard (
          seq notFoundGuard (getAttrFromPath attrPath (if useLegacy then legacyPackages else packages))
        );
        nullGuard =
          abortIf (selected == null)
            "icedos.system.extra-flakes: output '${outputPath}' on flake input '${flakeName}' is missing or null";
        drvGuard = seq nullGuard (
          abortIf (!isDerivation selected)
            "icedos.system.extra-flakes: output '${outputPath}' on flake input '${flakeName}' is not a package"
        );
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
