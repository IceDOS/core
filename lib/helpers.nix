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
    replaceStrings
    ;

  inherit (icedosLib) generateAttrPath;

  inherit (lib)
    concatMap
    concatMapStrings
    concatStringsSep
    escapeShellArg
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

  # Walks the toolset command tree and yields one record per branch node (a
  # node with at least one child), describing which children are valid
  # completions at that point in the command line. Used by the shell
  # completion generators below.
  toolsetBranches =
    commands:
    let
      go =
        parentPath: cmds:
        if cmds == [ ] then
          [ ]
        else
          [
            {
              path = parentPath;
              children = sort (a: b: a.name < b.name) (
                map (c: {
                  name = c.command;
                  help = c.help;
                }) cmds
              );
            }
          ]
          ++ concatMap (c: go (parentPath ++ [ c.command ]) c.commands) cmds;
    in
    go [ ] commands;

  mkBashCompletion =
    { commands }:
    let
      branches = toolsetBranches commands;
      childNames = b: concatStringsSep " " (map (c: c.name) b.children);
      caseArm = b: ''
        ${escapeShellArg (concatStringsSep " " b.path)})
            words=${escapeShellArg (childNames b)}
            ;;
      '';
    in
    ''
      _icedos() {
          local cur="''${COMP_WORDS[COMP_CWORD]}"
          local -a _icedos_args=("''${COMP_WORDS[@]:1:$((COMP_CWORD - 1))}")
          local IFS=' '
          local key="''${_icedos_args[*]}"
          local words=""
          case "$key" in
      ${concatMapStrings (b: "      " + caseArm b) branches}      esac
          COMPREPLY=( $(compgen -W "$words" -- "$cur") )
      }
      complete -F _icedos icedos
    '';

  mkZshCompletion =
    { commands }:
    let
      branches = toolsetBranches commands;
      # Escape colons (zsh _describe's name/help delimiter) with a backslash.
      escColons = replaceStrings [ ":" ] [ "\\:" ];
      entryStr = c: escapeShellArg "${c.name}:${escColons c.help}";
      caseArm = b: ''
        ${escapeShellArg (concatStringsSep " " b.path)})
            entries=(
      ${concatMapStrings (c: "          " + entryStr c + "\n") b.children}          )
            ;;
      '';
    in
    ''
      #compdef icedos
      _icedos() {
          local -a path entries
          local key
          path=("''${(@)words[2,$((CURRENT - 1))]}")
          key="''${(j: :)path}"
          entries=()
          case "$key" in
      ${concatMapStrings (b: "      " + caseArm b) branches}      esac
          if (( ''${#entries} > 0 )); then
              _describe -t commands 'icedos command' entries
          fi
      }
      _icedos "$@"
    '';

  mkFishCompletion =
    { commands }:
    let
      branches = toolsetBranches commands;
      line =
        c:
        "        printf '%s\\t%s\\n' ${escapeShellArg c.name} ${escapeShellArg c.help}\n";
      caseArm = b: ''
        case ${escapeShellArg (concatStringsSep " " b.path)}
      ${concatMapStrings line b.children}'';
    in
    ''
      function __icedos_complete_path
          set -l tokens (commandline -opc)
          set -l cur (commandline -ct)
          set -e tokens[1]
          if test -n "$cur"; and set -q tokens[1]
              set -e tokens[-1]
          end
          string join ' ' -- $tokens
      end

      function __icedos_complete
          switch (__icedos_complete_path)
      ${concatMapStrings (b: "        " + caseArm b) branches}    end
      end

      complete -c icedos -f -a '(__icedos_complete)'
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
