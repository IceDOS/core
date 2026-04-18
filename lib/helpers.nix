{
  icedosLib,
  lib,
  self,
  ...
}:

let
  inherit (builtins)
    attrNames
    listToAttrs
    pathExists
    ;

  inherit (icedosLib) generateAttrPath;

  inherit (lib)
    concatMapStrings
    fileContents
    filterAttrs
    flatten
    mapAttrsToList
    sort
    ;

  inherit (icedosLib) stringStartsWith;

in
rec {
  colorBashHeader = ''
    NC='\033[0m'
    PURPLE='\033[0;35m'
    RED='\033[0;31m'
  '';

  helpFlags = ''"$1" == "" || "$1" == "--help" || "$1" == "-h" || "$1" == "help" || "$1" == "h"'';

  purpleString = s: "\${PURPLE}${s}\${NC}";
  redString = s: "\${RED}${s}\${NC}";

  mkToolsetDispatcher =
    { commands }:
    let
      sorted = sort (a: b: a.command < b.command) commands;
    in
    ''
      ${colorBashHeader}

      if [[ ${helpFlags} ]]; then
        echo "Available commands:"

        ${concatMapStrings (c: ''
          echo -e "> ${purpleString c.command}: ${c.help} "
        '') sorted}

        exit 0
      fi

      case "$1" in
        ${concatMapStrings (c: ''
          ${c.command})
            shift
            exec ${c.bin} "$@"
            ;;
        '') commands}
        *|-*|--*)
          echo -e "${redString "Unknown arg"}: $1" >&2
          exit 1
          ;;
      esac
    '';

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

  pkgMapper = pkgs: pkgList: map (pkgName: generateAttrPath pkgs pkgName) pkgList;

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

  generatePackageOverlaysFromChannel = channel: packages: [
    (
      self: super:
      listToAttrs (
        map (package: {
          name = package;
          value = generateAttrPath super.${channel} package;
        }) packages
      )
    )
  ];
}
