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
    mapAttrs
    mapAttrsToList
    sort
    ;

  inherit (icedosLib) stringStartsWith;

in
rec {
  # Runtime bash helpers shared between Nix-embedded scripts (via the
  # auto-prepended `prelude` from toolset.nix:41) and standalone .sh files
  # (which `source` core/lib/prelude.sh directly). Both layers see the
  # same color vars, log_* / die / is_help_flag functions.
  bash = {
    prelude = builtins.readFile ./prelude.sh;

    genHelpFlags =
      {
        excludeNoArgs ? false,
      }:
      let
        base = ''"$1" == "--help" || "$1" == "-h" || "$1" == "help" || "$1" == "h"'';
      in
      if excludeNoArgs then base else ''"$1" == "" || '' + base;

    blueString = s: "\${BLUE}${s}\${NC}";
    greenString = s: "\${GREEN}${s}\${NC}";
    purpleString = s: "\${PURPLE}${s}\${NC}";
    redString = s: "\${RED}${s}\${NC}";
    yellowString = s: "\${YELLOW}${s}\${NC}";

    dimBlueString = s: "\${DIM_BLUE}${s}\${NC}";
    dimGreenString = s: "\${DIM_GREEN}${s}\${NC}";
    dimPurpleString = s: "\${DIM_PURPLE}${s}\${NC}";
    dimRedString = s: "\${DIM_RED}${s}\${NC}";
    dimYellowString = s: "\${DIM_YELLOW}${s}\${NC}";
  };

  # icedos toolset framework: the dispatcher generator (used to build
  # `icedos` itself and every subcommand attrset that has children) and
  # the per-shell completion generators. `walkBranches` is a private
  # helper consumed only by the three completion generators.
  toolset =
    let
      # Walks the command tree and yields one record per branch node (a
      # node with at least one child), describing which children are
      # valid completions at that point in the command line.
      walkBranches =
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
    in
    {
      mkDispatcher =
        { commands }:
        let
          sorted = sort (a: b: a.command < b.command) commands;

          inherit (bash)
            prelude
            genHelpFlags
            purpleString
            redString
            ;
        in
        ''
          ${prelude}

          if [[ ${genHelpFlags { }} ]]; then
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

      mkBashCompletion =
        { commands }:
        let
          branches = walkBranches commands;
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
          branches = walkBranches commands;
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
          branches = walkBranches commands;
          line = c: "        printf '%s\\t%s\\n' ${escapeShellArg c.name} ${escapeShellArg c.help}\n";

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
    };

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

  users = {
    getNormal =
      { users }:
      mapAttrsToList (name: attrs: {
        inherit name;
        value = attrs;
      }) (filterAttrs (n: v: v.isNormalUser) users);

    # Per-normal-user attrset for `users` submodule options. Lets modules avoid
    # forcing the user to write `[icedos.<path>.users.<name>]` per system user
    # just to materialise the option's submodule defaults.
    genDefaults =
      {
        users,
        value ? { },
      }:
      mapAttrs (_: _: value) (filterAttrs (_: v: v.isNormalUser) users);
  };

  pkgs = {
    mapper = pkgs: pkgList: map (pkgName: generateAttrPath pkgs pkgName) pkgList;

    overlaysFromChannel = channel: packages: [
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
  };

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
