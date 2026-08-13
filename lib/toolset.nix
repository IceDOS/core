{
  icedosLib,
  lib,
  self,
  ...
}:

let
  inherit (builtins)
    foldl'
    replaceStrings
    stringLength
    ;

  inherit (lib)
    concatMap
    concatMapStrings
    concatStrings
    concatStringsSep
    escapeShellArg
    genList
    max
    sort
    ;
in
rec {
  # Dispatcher generator (`icedos` itself and every subcommand with children)
  # plus the per-shell completion generators.
  toolset =
    let
      # One record per branch node: which children complete at that point.
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

      # One record per leaf that opted into `completion.files`.
      walkFileLeaves =
        commands:
        let
          go =
            parentPath: cmds:
            concatMap (
              c:
              let
                myPath = parentPath ++ [ c.command ];
                isFileLeaf = c.commands == [ ] && (c.completion.files or false);
              in
              (if isFileLeaf then [ { path = myPath; } ] else [ ]) ++ go myPath c.commands
            ) cmds;
        in
        go [ ] commands;

      # One record per leaf with a `completion.command` snippet, carrying the
      # leaf path and that snippet.
      walkValueLeaves =
        commands:
        let
          go =
            parentPath: cmds:
            concatMap (
              c:
              let
                myPath = parentPath ++ [ c.command ];
                isValueLeaf = c.commands == [ ] && (c.completion.command or "") != "";
              in
              (
                if isValueLeaf then
                  [
                    {
                      path = myPath;
                      cmd = c.completion.command;
                    }
                  ]
                else
                  [ ]
              )
              ++ go myPath c.commands
            ) cmds;
        in
        go [ ] commands;
    in
    {
      mkDispatcher =
        { commands }:
        let
          sorted = sort (a: b: a.command < b.command) commands;
          maxLen = foldl' max 0 (map (c: stringLength c.command) sorted);
          pad = s: s + concatStrings (genList (_: " ") (maxLen - stringLength s));

          # Pads to `globalCmdWidth - depth * 2`, so help text lands in one column
          # across the whole tree instead of per-subtree.
          renderTree =
            let
              walk =
                depth: cmds:
                concatMap (c: [ (depth * 2 + stringLength c.command) ] ++ walk (depth + 1) c.commands) cmds;
              globalCmdWidth = foldl' max 0 (walk 0 sorted);

              go =
                depth: cmds:
                let
                  sortedAtDepth = sort (a: b: a.command < b.command) cmds;
                  padTarget = globalCmdWidth - (depth * 2);
                  padAtDepth = s: s + concatStrings (genList (_: " ") (padTarget - stringLength s));
                  indent = concatStrings (genList (_: "  ") depth);
                in
                concatMapStrings (
                  c:
                  ''
                    echo -e "${indent}> ${purpleString (padAtDepth c.command)}    ${c.help}"
                  ''
                  + (if c.commands != [ ] then go (depth + 1) c.commands else "")
                ) sortedAtDepth;
            in
            go;

          inherit (icedosLib.bash)
            prelude
            genHelpFlags
            purpleString
            redString
            ;
        in
        ''
          ${prelude}

          if [[ "$1" == "--tree" ]]; then
            echo "Available commands:"

            ${renderTree 0 sorted}

            exit 0
          fi

          if [[ ${genHelpFlags { }} ]]; then
            echo "Available commands:"

            ${concatMapStrings (c: ''
              echo -e "> ${purpleString (pad c.command)}    ${c.help}"
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
          fileLeaves = walkFileLeaves commands;
          valueLeaves = walkValueLeaves commands;
          childNames = b: concatStringsSep " " (map (c: c.name) b.children);
          branchArm = b: ''
            ${escapeShellArg (concatStringsSep " " b.path)})
                words=${escapeShellArg (childNames b)}
                ;;
          '';
          # Matches the exact path and `<path> *`, so completion fires on every
          # positional argument, not just the first.
          fileLeafArm =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            ''
              ${escapeShellArg p} | ${escapeShellArg "${p} "}*)
                  if declare -F _filedir >/dev/null 2>&1; then
                      _filedir
                  else
                      COMPREPLY=( $(compgen -f -- "$cur") )
                  fi
                  return
                  ;;
            '';
          # IFS is reset to newline: the function body sets `IFS=' '` for the key
          # join, which would mis-split the snippet's candidates.
          valueLeafArm =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            ''
              ${escapeShellArg p} | ${escapeShellArg "${p} "}*)
                  local IFS=$'\n'
                  COMPREPLY=( $(compgen -W "$(${l.cmd})" -- "$cur") )
                  return
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
          ${concatMapStrings (l: "      " + valueLeafArm l) valueLeaves}${
            concatMapStrings (l: "      " + fileLeafArm l) fileLeaves
          }${concatMapStrings (b: "      " + branchArm b) branches}      esac
              COMPREPLY=( $(compgen -W "$words" -- "$cur") )
          }
          complete -F _icedos icedos
        '';

      mkZshCompletion =
        { commands }:
        let
          branches = walkBranches commands;
          fileLeaves = walkFileLeaves commands;
          valueLeaves = walkValueLeaves commands;
          # Escape colons (zsh _describe's name/help delimiter) with a backslash.
          escColons = replaceStrings [ ":" ] [ "\\:" ];
          entryStr = c: escapeShellArg "${c.name}:${escColons c.help}";
          branchArm = b: ''
              ${escapeShellArg (concatStringsSep " " b.path)})
                  entries=(
            ${concatMapStrings (c: "          " + entryStr c + "\n") b.children}          )
                  ;;
          '';
          fileLeafArm =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            ''
              ${escapeShellArg p} | ${escapeShellArg "${p} "}*)
                  _files
                  return
                  ;;
            '';
          # Value-completing leaves: run the snippet, split its output on
          # newlines (the `f` flag), and offer the lines via compadd.
          valueLeafArm =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            ''
              ${escapeShellArg p} | ${escapeShellArg "${p} "}*)
                  local -a vals
                  vals=("''${(@f)$(${l.cmd})}")
                  compadd -a vals
                  return
                  ;;
            '';
        in
        ''
          #compdef icedos
          _icedos() {
              local -a _icedos_path entries
              local key
              _icedos_path=("''${(@)words[2,$((CURRENT - 1))]}")
              key="''${(j: :)_icedos_path}"
              entries=()
              case "$key" in
          ${concatMapStrings (l: "      " + valueLeafArm l) valueLeaves}${
            concatMapStrings (l: "      " + fileLeafArm l) fileLeaves
          }${concatMapStrings (b: "      " + branchArm b) branches}      esac
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
          fileLeaves = walkFileLeaves commands;
          valueLeaves = walkValueLeaves commands;
          line = c: "        printf '%s\\t%s\\n' ${escapeShellArg c.name} ${escapeShellArg c.help}\n";

          caseArm = b: ''
              case ${escapeShellArg (concatStringsSep " " b.path)}
            ${concatMapStrings line b.children}'';

          # Gated on the argv prefix, so `-F` overrides the global `-f` only at that
          # leaf and branch nodes still complete subcommand names.
          fileLeafComplete =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            "complete -c icedos -F -n ${escapeShellArg ''__icedos_path_match "${p}"''}\n";

          # fish can't inline a quoted command in `complete -a`, so each value leaf
          # gets a wrapper function.
          fnName = l: "__icedos_vals_" + replaceStrings [ " " ] [ "_" ] (concatStringsSep " " l.path);
          valueLeafFn = l: ''
            function ${fnName l}
                ${l.cmd}
            end
          '';
          valueLeafComplete =
            l:
            "complete -c icedos -f -n ${escapeShellArg ''__icedos_path_match "${concatStringsSep " " l.path}"''} -a ${escapeShellArg "(${fnName l})"}\n";
        in
        ''
          function __icedos_complete_path
              set -l tokens (commandline -opc)
              set -e tokens[1]
              if set -q tokens[1]
                  string join ' ' -- $tokens
              end
          end

          function __icedos_path_match
              set -l p (__icedos_complete_path)
              test "$p" = "$argv[1]"; and return 0
              string match -q -- "$argv[1] *" "$p"
          end

          function __icedos_complete
              set -l p (__icedos_complete_path)
              switch "$p"
          ${concatMapStrings (b: "        " + caseArm b) branches}    end
          end

          ${concatMapStrings valueLeafFn valueLeaves}complete -c icedos -f -a '(__icedos_complete)'
          ${concatMapStrings fileLeafComplete fileLeaves}${concatMapStrings valueLeafComplete valueLeaves}'';
    };

}
