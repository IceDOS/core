{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.icedos.system.toolset) commands desktopEntries sessionCommands;
  inherit (icedosLib.bash) prelude;

  inherit (icedosLib.toolset)
    mkBashCompletion
    mkDispatcher
    mkFishCompletion
    mkZshCompletion
    ;

  inherit (lib) concatMap optional;
  validNameRegex = "[a-zA-Z0-9_-]+";

  # Recursively merge commands sharing a name by concatenating their `commands`
  # children. Without this, two modules registering e.g. `claude` with different
  # subcommands (`limits`, `mcp`) produce duplicate case labels in the root
  # dispatcher — bash always matches the first. Recursion handles the same
  # scenario at any depth.
  mergeCommands =
    cmds:
    let
      # Fold over commands, tracking each original entry's classification for the
      # validation step below — a `_entries` list per group is accumulated so we
      # can detect leaf/branch collisions across modules.
      grouped = builtins.foldl' (
        acc: cmd:
        if builtins.hasAttr cmd.command acc then
          acc
          // {
            ${cmd.command} = acc.${cmd.command} // {
              commands = acc.${cmd.command}.commands ++ cmd.commands;
              _entries = acc.${cmd.command}._entries ++ [
                {
                  hasCommands = cmd.commands != [ ];
                  hasScriptOrBin = cmd.script != "" || cmd.bin != "";
                }
              ];
            };
          }
        else
          acc
          // {
            ${cmd.command} = cmd // {
              _entries = [
                {
                  hasCommands = cmd.commands != [ ];
                  hasScriptOrBin = cmd.script != "" || cmd.bin != "";
                }
              ];
            };
          }
      ) { } cmds;

      # Validate cross-module collisions: if multiple entries share a name and
      # disagree on leaf vs branch classification, or if multiple leaves collide,
      # the outcome is order-dependent (NixOS list concatenation decides which
      # definition wins). A single-entry group that declares both `commands` and
      # `script`/`bin` is already caught by the accurate assertion below and
      # falls through.
      check =
        name: entry:
        let
          entries = entry._entries;
          n = builtins.length entries;
          anyBranch = builtins.any (x: x.hasCommands) entries;
          anyLeaf = builtins.any (x: x.hasScriptOrBin) entries;
          leafCount = builtins.foldl' (acc: x: if x.hasScriptOrBin then acc + 1 else acc) 0 entries;
        in
        if n > 1 && anyBranch && anyLeaf then
          builtins.abort ''
            icedos toolset: command "${name}" is registered as BOTH a leaf (script/bin)
            and a branch (subcommands) by different modules. This is ambiguous —
            NixOS list ordering decides which definition wins. Use unique command
            names or consolidate the definitions into a single module.''
        else if n > 1 && leafCount > 1 then
          builtins.abort ''
            icedos toolset: command "${name}" has multiple leaf definitions
            (script/bin) from different modules (${toString leafCount} registrations).
            Only the first survives — rename or consolidate.''
        else
          true;

      validated = builtins.all (n: check n grouped.${n}) (builtins.attrNames grouped);
      merged = builtins.attrValues grouped;
    in
    builtins.seq validated (
      map (
        cmd:
        builtins.removeAttrs cmd [ "_entries" ]
        // {
          commands = mergeCommands cmd.commands;
        }
      ) merged
    );

  mergedCommands = mergeCommands commands;

  rebootBin = pkgs.writeShellScriptBin "icedos-reboot" ''
    exec ${pkgs.systemd}/bin/run0 ${pkgs.systemd}/bin/systemctl reboot -i
  '';

  rebootUefiBin = pkgs.writeShellScriptBin "icedos-reboot-uefi" ''
    exec ${pkgs.systemd}/bin/run0 ${pkgs.systemd}/bin/systemctl reboot --firmware-setup -i
  '';

  logoutBin = pkgs.writeShellScriptBin "icedos-logout" ''
    exec ${pkgs.systemd}/bin/loginctl terminate-user "$USER"
  '';

  poweroffBin = pkgs.writeShellScriptBin "icedos-poweroff" ''
    exec ${pkgs.systemd}/bin/run0 ${pkgs.systemd}/bin/systemctl poweroff -i
  '';

  suspendBin = pkgs.writeShellScriptBin "icedos-suspend" ''
    exec ${pkgs.systemd}/bin/run0 ${pkgs.systemd}/bin/systemctl suspend -i
  '';

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
            pkgs.writeShellScript cmd.command (mkDispatcher {
              commands = resolvedChildren;
            })
          )
        else if hasScript then
          toString (pkgs.writeShellScript cmd.command "${prelude}\n${cmd.script}")
        else
          cmd.bin;
    };

  resolvedCommands = map resolve mergedCommands;

  flatten = cmd: [ cmd ] ++ concatMap flatten cmd.commands;
  allCommands = concatMap flatten mergedCommands;
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
        (pkgs.writeShellScriptBin "icedos" (mkDispatcher {
          commands = resolvedCommands;
        }))

        (pkgs.writeTextFile {
          name = "icedos-bash-completion";
          destination = "/share/bash-completion/completions/icedos";
          text = mkBashCompletion { commands = mergedCommands; };
        })

        (pkgs.writeTextFile {
          name = "icedos-zsh-completion";
          destination = "/share/zsh/site-functions/_icedos";
          text = mkZshCompletion { commands = mergedCommands; };
        })

        (pkgs.writeTextFile {
          name = "icedos-fish-completion";
          destination = "/share/fish/vendor_completions.d/icedos.fish";
          text = mkFishCompletion { commands = mergedCommands; };
        })
      ];
    })
  ];

  icedos.system.toolset.commands = [
    {
      command = "session";
      help = "session lifecycle commands";

      commands = [
        {
          command = "reboot";

          script = ''
            case "$1" in
              "")
                systemctl reboot -i || sudo systemctl reboot -i
                ;;
              uefi)
                systemctl reboot --firmware-setup -i || sudo systemctl reboot --firmware-setup -i
                ;;
              *)
                die "unknown arg: $1"
                ;;
            esac
          '';

          help = "reboot ignoring inhibitors and users, uefi supported by appending it as an argument";
        }
        {
          command = "logout";
          script = "loginctl terminate-user $USER";
          help = "terminate all sessions for the current user via loginctl";
        }
        {
          command = "poweroff";
          script = "systemctl poweroff -i || sudo systemctl poweroff -i";
          help = "power off ignoring inhibitors and users";
        }
        {
          command = "suspend";
          script = "systemctl suspend -i || sudo systemctl suspend -i";
          help = "suspend ignoring inhibitors and users";
        }
      ]
      ++ sessionCommands;
    }
    {
      command = "nixf";
      script = ''find "''${1:-.}" -type f -name "*.nix" -exec "${pkgs.nixfmt}/bin/nixfmt" {} \;'';
      help = "format all nix files of current or provided directory";

      completion.files = true;
    }
  ];

  home-manager.sharedModules = optional desktopEntries {
    xdg.desktopEntries.icedos-reboot = {
      name = "Reboot";
      genericName = "Restart the system";
      comment = "Reboot the system, ignoring inhibitors and other logged-in users";
      icon = "system-reboot";
      exec = "${rebootBin}/bin/icedos-reboot";
      terminal = false;
      type = "Application";

      categories = [
        "System"
        "Settings"
      ];

      settings.Keywords = "reboot;restart;shutdown;";
    };

    xdg.desktopEntries.icedos-reboot-uefi = {
      name = "Reboot to UEFI";
      genericName = "Restart into firmware setup";
      comment = "Reboot the system into the UEFI firmware setup screen";
      icon = "system-reboot";
      exec = "${rebootUefiBin}/bin/icedos-reboot-uefi";
      terminal = false;
      type = "Application";

      categories = [
        "System"
        "Settings"
      ];

      settings.Keywords = "reboot;restart;uefi;firmware;bios;";
    };

    xdg.desktopEntries.icedos-logout = {
      name = "Logout";
      genericName = "Logout from current session";
      comment = "Terminate all sessions for the current user via loginctl";
      icon = "system-log-out";
      exec = "${logoutBin}/bin/icedos-logout";
      terminal = false;
      type = "Application";

      categories = [
        "System"
        "Settings"
      ];

      settings.Keywords = "logout;user;";
    };

    xdg.desktopEntries.icedos-poweroff = {
      name = "Power Off";
      genericName = "Shut down the system";
      comment = "Power off the system, ignoring inhibitors and other logged-in users";
      icon = "system-shutdown";
      exec = "${poweroffBin}/bin/icedos-poweroff";
      terminal = false;
      type = "Application";

      categories = [
        "System"
        "Settings"
      ];

      settings.Keywords = "poweroff;shutdown;halt;";
    };

    xdg.desktopEntries.icedos-suspend = {
      name = "Suspend";
      genericName = "Suspend the system";
      comment = "Suspend the system, ignoring inhibitors and other logged-in users";
      icon = "system-suspend";
      exec = "${suspendBin}/bin/icedos-suspend";
      terminal = false;
      type = "Application";

      categories = [
        "System"
        "Settings"
      ];

      settings.Keywords = "suspend;sleep;";
    };
  };
}
