{
  icedosLib,
  inputs ? { },
  lib,
  self,
  ...
}:

let
  inherit (builtins)
    elemAt
    isAttrs
    length
    listToAttrs
    seq
    ;

  inherit (lib)
    concatStringsSep
    getAttrFromPath
    hasAttrByPath
    splitString
    sublist
    ;

  inherit (icedosLib)
    _selectExtraFlakeOutput
    abortIf
    generateAttrPath
    ;

  resolvePackage =
    {
      pkgs,
      inputs ? inputs,
    }:
    pkgName:
    let
      inherit (pkgs.stdenv.hostPlatform) system;
      parts = splitString "." pkgName;
    in
    if (length parts >= 2) && (elemAt parts 0 == "icedosExtraFlakes") then
      let
        lengthGuard =
          abortIf (length parts < 3)
            "icedos.system.extra-flakes: package string '${pkgName}' is missing package name (format: icedosExtraFlakes.<flake>.<package>)";
        flakeName = elemAt parts 1;
        attrPath = sublist 2 (length parts - 2) parts;
        attrString = concatStringsSep "." attrPath;
        flake = seq lengthGuard (_selectExtraFlakeOutput flakeName "" inputs);
        packages = flake.packages.${system} or null;
        legacyPackages = flake.legacyPackages.${system} or null;
        systemGuard = abortIf (
          packages == null && legacyPackages == null
        ) "icedos.system.extra-flakes: flake '${flakeName}' has no packages for system '${system}'";
        hasPkg = packages != null && hasAttrByPath attrPath packages;
        hasLegacyPkg = legacyPackages != null && hasAttrByPath attrPath legacyPackages;
        pkgGuard = seq systemGuard (
          abortIf (!hasPkg && !hasLegacyPkg)
            "icedos.system.extra-flakes: package '${attrString}' is not found in flake '${flakeName}' for system '${system}'"
        );
      in
      seq pkgGuard (
        if hasPkg then getAttrFromPath attrPath packages else getAttrFromPath attrPath legacyPackages
      )
    else
      generateAttrPath pkgs pkgName;
in
rec {
  pkgs = rec {
    mapper =
      pkgsOrArgs:
      let
        isArgs = isAttrs pkgsOrArgs && pkgsOrArgs ? pkgs;
        resolvedPkgs = if isArgs then pkgsOrArgs.pkgs else pkgsOrArgs;
        resolvedInputs = if isArgs then (pkgsOrArgs.inputs or inputs) else inputs;
      in
      pkgList:
      map (resolvePackage {
        pkgs = resolvedPkgs;
        inputs = resolvedInputs;
      }) pkgList;

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
