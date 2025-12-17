let
  inherit (builtins) getEnv readFile toJSON;
  config = (fromTOML (readFile ../config.toml));
  inherit (config) icedos;

  system = icedos.system.arch or "x86_64-linux";
  pkgs = import <nixpkgs> { inherit system; };
  inherit (pkgs) lib;

  inherit (lib)
    boolToString
    concatMapStrings
    concatStringsSep
    evalModules
    fileContents
    foldl'
    listToAttrs
    map
    pathExists
    recursiveUpdate
    ;

  icedosLib = import ../lib {
    inherit lib pkgs;
    config = icedos;
    self = ./..;
    inputs = { };
  };

  inherit (icedosLib) injectIfExists modulesFromConfig;

  channels = icedos.system.channels or [ ];
  configurationLocation = getEnv "ICEDOS_CONFIG_PATH";
  isFirstBuild = !pathExists "/run/current-system/source" || (icedos.system.forceFirstBuild or false);

  nixpkgsInput = {
    name = "nixpkgs";

    value = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };
  };

  homeManagerInput = {
    name = "home-manager";

    value = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  extraModulesInputs = modulesFromConfig.inputs ++ [
    homeManagerInput
    nixpkgsInput
  ];

  flakeInputs = listToAttrs (
    extraModulesInputs
    ++ (map (c: {
      inherit (c) name;
      value = { inherit (c) url; };
    }) channels)
  );

  nixosModulesText = modulesFromConfig.nixosModulesText;

  evaluatedConfig =
    toJSON
      (evalModules {
        modules = [
          {
            inherit config;

            options =
              let
                mergedOptions =
                  foldl' (acc: cur: recursiveUpdate acc cur.options)
                    (import ../modules/options.nix { inherit icedosLib lib; }).options
                    modulesFromConfig.options;
              in
              mergedOptions;
          }
        ];
      }).config;
in
{
  inherit flakeInputs evaluatedConfig;

  flakeFinal = ''
    {
      inputs = {
        ${getEnv "ICEDOS_FLAKE_INPUTS"}
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
          inherit (lib) fileContents map;

          inherit (builtins) fromTOML;
          inherit ((fromTOML (fileContents ./config.toml))) icedos;

          icedosLib = import ./lib {
            inherit lib pkgs inputs;
            config = icedos;
            self = ./.;
          };

          inherit (icedosLib) modulesFromConfig;
        in {
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

                  config.environment.sessionVariables.ICEDOS_CONFIG_PATH = "${configurationLocation}";
                }
              )

              # Symlink configuration state on "/run/current-system/source"
              {
                # Source: https://github.com/NixOS/nixpkgs/blob/5e4fbfb6b3de1aa2872b76d49fafc942626e2add/nixos/modules/system/activation/top-level.nix#L191
                system.systemBuilderCommands = "ln -s ''${self} $out/source";
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
                  imports = [ ./modules/options.nix ] ++ getModules ./.extra ++ getModules ./.private;
                  config.system.stateVersion = "${icedos.system.version}";
                }
              )

              home-manager.nixosModules.home-manager

              ${concatMapStrings (channel: ''
                (
                  {config, ...}: {
                    nixpkgs.config.packageOverrides."${channel.name}" = import inputs."${channel.name}" {
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
            ++ modulesFromConfig.options
            ++ (modulesFromConfig.nixosModules { inherit inputs; });
          };
        };
    }
  '';
}
