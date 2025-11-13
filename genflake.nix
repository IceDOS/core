let
  inherit (builtins) readFile;

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

  cfg = (fromTOML (readFile ./config.toml)).icedos;
  system = cfg.system.arch or "x86_64-linux";
  pkgs = import <nixpkgs> { inherit system; };

  icedosLib = import ./lib.nix {
    inherit lib pkgs;
    config = cfg;
    self = ./.;
  };

  channels = cfg.system.channels or [ ];
  configurationLocation = fileContents "/tmp/icedos/configuration-location";
  isFirstBuild = !pathExists "/run/current-system/source" || (cfg.system.forceFirstBuild or false);

  externalModulesOutputs = map icedosLib.getExternalModuleOutputs cfg.repositories;
  extraModulesInputs = flatten (map (mod: mod.inputs) externalModulesOutputs);

  flakeInputs = icedosLib.serializeAllExternalInputs (listToAttrs extraModulesInputs);
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

          inherit (builtins) fromTOML;
          inherit (lib) fileContents flatten map;
          inherit (pkgs) lib;

          cfg = (fromTOML (fileContents ./config.toml)).icedos;
          pkgs = nixpkgs.legacyPackages.''${system};

          icedosLib = import ./lib.nix {
            inherit lib pkgs inputs;
            config = cfg;
            self = ./.;
          };

          externalModulesOutputs =
            map
            icedosLib.getExternalModuleOutputs
            cfg.repositories;

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
                  config.system.stateVersion = "${cfg.system.version}";
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

              ${icedosLib.injectIfExists { file = "/etc/nixos/hardware-configuration.nix"; }}
              ${icedosLib.injectIfExists { file = "/etc/nixos/extras.nix"; }}
            ] ++ extraOptions ++ extraNixosModules;
          };
        };
    }
  '';
}
