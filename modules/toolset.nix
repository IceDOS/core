{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.icedos.applications.toolset) commands;

  inherit (icedosLib)
    mkBashCompletion
    mkFishCompletion
    mkToolsetDispatcher
    mkZshCompletion
    ;

  inherit (lib) concatMap;
  validNameRegex = "[a-zA-Z0-9_-]+";

  resolve =
    cmd:
    let
      resolvedChildren = map resolve cmd.commands;
      hasChildren = cmd.commands != [ ];
      hasScript = cmd.script != "";
    in
    cmd
    // {
      commands = resolvedChildren;
      bin =
        if hasChildren then
          toString (
            pkgs.writeShellScript cmd.command (mkToolsetDispatcher {
              commands = resolvedChildren;
            })
          )
        else if hasScript then
          toString (pkgs.writeShellScript cmd.command cmd.script)
        else
          cmd.bin;
    };

  resolvedCommands = map resolve commands;

  flatten = cmd: [ cmd ] ++ concatMap flatten cmd.commands;
  allCommands = concatMap flatten commands;
in
{
  assertions =
    (map (c: {
      assertion = !(c.commands != [ ] && (c.script != "" || c.bin != ""));
      message = ''icedos toolset command "${c.command}" declares subcommands but also sets script/bin; these are mutually exclusive.'';
    }) allCommands)
    ++ (map (c: {
      assertion = !(c.commands == [ ] && c.script != "" && c.bin != "");
      message = ''icedos toolset command "${c.command}" sets both script and bin; pick one.'';
    }) allCommands)
    ++ (map (c: {
      assertion = builtins.match validNameRegex c.command != null;
      message = ''icedos toolset command name "${c.command}" is invalid; must match ${validNameRegex}.'';
    }) allCommands);

  environment.systemPackages = [
    (pkgs.symlinkJoin {
      name = "icedos";
      paths = [
        (pkgs.writeShellScriptBin "icedos" (mkToolsetDispatcher {
          commands = resolvedCommands;
        }))

        (pkgs.writeTextFile {
          name = "icedos-bash-completion";
          destination = "/share/bash-completion/completions/icedos";
          text = mkBashCompletion { inherit commands; };
        })

        (pkgs.writeTextFile {
          name = "icedos-zsh-completion";
          destination = "/share/zsh/site-functions/_icedos";
          text = mkZshCompletion { inherit commands; };
        })

        (pkgs.writeTextFile {
          name = "icedos-fish-completion";
          destination = "/share/fish/vendor_completions.d/icedos.fish";
          text = mkFishCompletion { inherit commands; };
        })
      ];
    })
  ];
}
