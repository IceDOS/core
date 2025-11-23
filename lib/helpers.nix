{
  icedosLib,
  lib,
  pkgs,
  self,
  ...
}:

let
  inherit (builtins)
    attrNames
    foldl'
    map
    pathExists
    ;

  inherit (lib)
    fileContents
    filterAttrs
    flatten
    mapAttrsToList
    splitString
    ;

  inherit (icedosLib) stringStartsWith;

in
rec {
  generateAccentColor =
    {
      accentColor,
      gnomeAccentColor,
      hasGnome,
    }:
    if (!hasGnome) then
      "#${accentColor}"
    else
      {
        blue = "#3584e4";
        green = "#3a944a";
        orange = "#ed5b00";
        pink = "#d56199";
        purple = "#9141ac";
        red = "#e62d42";
        slate = "#6f8396";
        teal = "#2190a4";
        yellow = "#c88800";
      }
      .${gnomeAccentColor};

  getNormalUsers =
    { users }:
    mapAttrsToList (name: attrs: {
      inherit name;
      value = attrs;
    }) (filterAttrs (n: v: v.isNormalUser) users);

  pkgMapper =
    pkgList: map (pkgName: foldl' (acc: cur: acc.${cur}) pkgs (splitString "." pkgName)) pkgList;

  injectIfExists =
    { file }:
    if (pathExists file) then
      ''
        (
          ${fileContents file}
        )
      ''
    else
      "";

  scanModules =
    {
      path,
      filename,
      maxDepth ? -1,
    }:
    let
      inherit (builtins) readDir;
      inherit (lib) optional;

      getContentsByType = fileType: filterAttrs (name: type: type == fileType) contents;

      targetPath = if (stringStartsWith "/nix/store" "${path}") then "${path}" else "${self}/${path}";
      contents = readDir targetPath;

      directories = getContentsByType "directory";
      files = getContentsByType "regular";

      directoriesPaths = map (n: "${path}/${n}") (attrNames directories);

      icedosFiles = filterAttrs (n: v: n == filename) files;
      icedosFilesPaths = map (n: "${targetPath}/${n}") (attrNames icedosFiles);
    in
    icedosFilesPaths
    ++ optional (maxDepth != 0) (
      flatten (
        map (
          dp:
          scanModules {
            inherit filename;
            path = dp;
            maxDepth = maxDepth - 1;
          }
        ) directoriesPaths
      )
    );
}
