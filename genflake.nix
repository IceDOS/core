let
  inherit (builtins) readFile;
  inherit ((fromTOML (readFile ./config.toml))) icedos;

  system = icedos.system.arch or "x86_64-linux";
  pkgs = import <nixpkgs> { inherit system; };
  inherit (pkgs) lib;

  inherit (lib)
    boolToString
    concatMapStrings
    concatStringsSep
    fileContents
    flatten
    listToAttrs
    map
    pathExists
    ;

  icedosLib = import ./lib.nix {
    inherit lib pkgs;
    config = icedos;
    self = ./.;
  };

  inherit (icedosLib) getExternalModuleOutputs serializeAllExternalInputs injectIfExists;

  channels = icedos.system.channels or [ ];
  configurationLocation = fileContents "/tmp/icedos/configuration-location";
  isFirstBuild = !pathExists "/run/current-system/source" || (icedos.system.forceFirstBuild or false);

  externalModulesOutputs = map getExternalModuleOutputs icedos.repositories or [ ];
  extraModulesInputs = flatten (map (mod: mod.inputs) externalModulesOutputs);

  flakeInputs = serializeAllExternalInputs (listToAttrs extraModulesInputs);
  nixosModulesText = flatten (map (mod: mod.nixosModulesText) externalModulesOutputs);
in
{
  flake.nix = ''
    {
      inputs = {
        ${flakeInputs}
      };

      outputs =
        {
          home-manager,
          nixpkgs,
          self,
          ...
        }@inputs:
        let
          system = "${system}";
          pkgs = nixpkgs.legacyPackages.''${system};
          inherit (pkgs) lib;
          inherit (lib) fileContents flatten map;

          inherit (builtins) fromTOML;
          inherit ((fromTOML (fileContents ./config.toml))) icedos;

          icedosLib = import ./lib.nix {
            inherit lib pkgs inputs;
            config = icedos;
            self = ./.;
          };

          inherit (icedosLib) getExternalModuleOutputs;

          externalModulesOutputs =
            map
            getExternalModuleOutputs
            icedos.repositories;

          extraOptions = flatten (map (mod: mod.options) externalModulesOutputs);

          extraNixosModules = flatten (map (mod: mod.nixosModules { inherit inputs; }) externalModulesOutputs);
        in {
          apps.''${system}.init = {
            type = "app";
            program = toString (with pkgs; writeShellScript "icedos-flake-init" "exit");
          };

          nixosConfigurations."${fileContents "/etc/hostname"}" = nixpkgs.lib.nixosSystem rec {
            specialArgs = {
              inherit icedosLib inputs;
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
                  imports = [./options.nix] ++ getModules ./.extra ++ getModules ./.private;
                  config.system.stateVersion = "${icedos.system.version}";
                }
              )

              home-manager.nixosModules.home-manager

              ${concatMapStrings (channel: ''
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

              ${concatStringsSep "\n" (map (text: "(${text})") nixosModulesText)}

              ${injectIfExists { file = "/etc/nixos/hardware-configuration.nix"; }}
              ${injectIfExists { file = "/etc/nixos/extras.nix"; }}
            ]
            ++ extraOptions
            ++ extraNixosModules;
          };
        };
    }
  '';
}
