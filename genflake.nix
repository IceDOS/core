let
  inherit (pkgs)
    lib
    ;

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

  system = "x86_64-linux";
  cfg = (fromTOML (fileContents ./config.toml)).icedos;
  pkgs = import <nixpkgs> { inherit system; };

  icedosLib = import ./icedos/lib {
    inherit lib pkgs;
    config = cfg;
    self = ./.;
    inputs = { };
  };

  channels = cfg.system.channels or [ ];
  configurationLocation = fileContents "/tmp/icedos/configuration-location";
  isFirstBuild = !pathExists "/run/current-system/source" || (cfg.system.forceFirstBuild or false);

  extraModulesInputs = icedosLib.modulesFromConfig.inputs;
  flakeInputs = icedosLib.serializeAllExternalInputs (listToAttrs extraModulesInputs);
  nixosModulesText = icedosLib.modulesFromConfig.nixosModulesText;
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

          icedosLib = import ./icedos/lib {
            inherit lib pkgs inputs;
            config = cfg;
            self = ./.;
          };
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
            ]
            ++ icedosLib.modulesFromConfig.options
            ++ (icedosLib.modulesFromConfig.nixosModules { inherit inputs; });
          };
        };
    }
  '';
}
