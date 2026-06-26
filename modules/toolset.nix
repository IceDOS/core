{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.icedos.applications.toolset) commands desktopEntries sessionCommands;

  inherit (icedosLib.bash) prelude;

  inherit (icedosLib.toolset)
    mkBashCompletion
    mkDispatcher
    mkFishCompletion
    mkZshCompletion
    ;

  inherit (lib) concatMap optional;
  validNameRegex = "[a-zA-Z0-9_-]+";

  rebootBin = pkgs.writeShellScriptBin "icedos-reboot" ''
    exec /run/wrappers/bin/pkexec ${pkgs.systemd}/bin/systemctl reboot -i
  '';

  rebootUefiBin = pkgs.writeShellScriptBin "icedos-reboot-uefi" ''
    exec /run/wrappers/bin/pkexec ${pkgs.systemd}/bin/systemctl reboot --firmware-setup -i
  '';

  logoutBin = pkgs.writeShellScriptBin "icedos-logout" ''
    exec ${pkgs.systemd}/bin/loginctl terminate-user "$USER"
  '';

  poweroffBin = pkgs.writeShellScriptBin "icedos-poweroff" ''
    exec /run/wrappers/bin/pkexec ${pkgs.systemd}/bin/systemctl poweroff -i
  '';

  suspendBin = pkgs.writeShellScriptBin "icedos-suspend" ''
    exec /run/wrappers/bin/pkexec ${pkgs.systemd}/bin/systemctl suspend -i
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
        (pkgs.writeShellScriptBin "icedos" (mkDispatcher {
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

  icedos.applications.toolset.commands = [
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
