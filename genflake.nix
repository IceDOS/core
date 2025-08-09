let
  inherit (lib)
    attrNames
    boolToString
    concatImapStrings
    concatMapStrings
    fileContents
    pathExists
    ;

  cfg = (import ./options.nix { inherit lib; }).config.icedos;
  lib = import <nixpkgs/lib>;

  channels = cfg.system.channels or [ ];

  kernel = cfg.hardware.kernel.version;

  chaotic = (
    kernel == "cachyos" || kernel == "cachyos-rc" || kernel == "cachyos-server" || kernel == "valve"
  );

  configurationLocation = fileContents "/tmp/configuration-location";
  isFirstBuild = !pathExists "/run/current-system/source" || (cfg.system.forceFirstBuild or false);
  users = attrNames cfg.users;

  injectIfExists =
    file:
    if (pathExists file) then
      ''
        (
          ${fileContents file}
        )
      ''
    else
      "";
in
{
  flake.nix = ''
    {
      inputs = {
        # Package repositories
        ${
          if chaotic then
            ''
              chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
            ''
          else
            ""
        }

        nixpkgs.${
          if chaotic then
            ''follows = "chaotic/nixpkgs";''
          else
            ''url = "github:NixOS/nixpkgs/nixos-unstable";''
        }

        ${concatImapStrings (
          i: channel: ''"${channel}".url = github:NixOS/nixpkgs/${channel};''\n''
        ) channels}

        # Modules
        home-manager = {
          url = "github:nix-community/home-manager";

          ${
            if chaotic then
              ''
                follows = "chaotic/home-manager";
              ''
            else
              ''
                inputs.nixpkgs.follows = "nixpkgs";
              ''
          }
        };

        ${
          if (kernel == "valve") then
            ''
              steam-session.follows = "chaotic/jovian";
            ''
          else
            ""
        }

        ${extraInputs}
      };

      outputs =
        {
          home-manager,
          nixpkgs,
          self,
          ${if chaotic then ''chaotic,'' else ""}
          ...
        }@inputs:
        {
          nixosConfigurations."${fileContents "/etc/hostname"}" = nixpkgs.lib.nixosSystem rec {
            system = "x86_64-linux";

            specialArgs = {
              inherit inputs;
            };

            modules = [
              # Read configuration location
              (
                { lib, ... }:
                let
                  inherit (lib) mkOption types;
                in
                {
                  options.icedos.configurationLocation = mkOption {
                    type = types.str;
                    default = "${configurationLocation}";
                  };
                }
              )

              # Symlink configuration state on "/run/current-system/source"
              {
                # Source: https://github.com/NixOS/nixpkgs/blob/5e4fbfb6b3de1aa2872b76d49fafc942626e2add/nixos/modules/system/activation/top-level.nix#L191
                system.extraSystemBuilderCmds = "ln -s ''${self} $out/source";
              }

              # Internal modules and config
              (
                { lib, ... }:
                let
                  inherit (lib) filterAttrs;

                  getModules =
                    path:
                    map (dir: "/''${path}/''${dir}") (
                      let
                        inherit (lib) attrNames;
                      in
                      attrNames (filterAttrs (n: v: v == "directory") (builtins.readDir path))
                    );
                in
                {
                  imports = [./options.nix] ++ getModules ./.private;
                  config.system.stateVersion = "${cfg.system.version}";
                }
              )

              # External modules
              ${
                if chaotic then
                  ''
                    chaotic.nixosModules.default
                  ''
                else
                  ""
              }

              home-manager.nixosModules.home-manager

              ${concatImapStrings (i: channel: ''
                (
                  {config, ...}: {
                    nixpkgs.config.packageOverrides."${channel}" = import inputs."${channel}" {
                      inherit system;
                      config = config.nixpkgs.config;
                    };
                  }
                )
              '') channels}

              { icedos.system.isFirstBuild = ${boolToString isFirstBuild}; }

              ${concatMapStrings (
                user: if (pathExists "${configurationLocation}/users/${user}") then "./users/${user}\n" else ""
              ) users}

              ${injectIfExists "/etc/nixos/hardware-configuration.nix"}
              ${injectIfExists "/etc/nixos/extras.nix"}
            ];
          };
        };
    }
  '';
}
