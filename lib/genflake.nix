let
  inherit (builtins) readFile toJSON;
  inherit (fromTOML (readFile "${ICEDOS_CONFIG_ROOT}/config.toml")) icedos;

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
    optional
    pathExists
    recursiveUpdate
    ;

  icedosLib = import ../lib {
    inherit lib pkgs;
    config = icedos;
    self = ./..;
    inputs = { };
  };

  inherit (icedosLib)
    ICEDOS_CONFIG_ROOT
    ICEDOS_FLAKE_INPUTS
    ICEDOS_STATE_DIR
    injectIfExists
    modulesFromConfig
    ;

  channels = icedos.system.channels or [ ];
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
    ++ [
      {
        name = "icedos-config";
        value = {
          url = "path:${ICEDOS_CONFIG_ROOT}";
        };
      }
      {
        name = "icedos-core";
        value = {
          follows = "icedos-config/icedos";
        };
      }
    ]
    ++ (optional (pathExists /etc/icedos) {
      name = "icedos-state";
      value = {
        url = "path:${/etc/icedos}";
        flake = false;
      };
    })
  );

  nixosModulesText = modulesFromConfig.nixosModulesText;

  evaluatedConfig =
    toJSON
      (evalModules {
        modules = [
          {
            config = icedos;

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
        ${ICEDOS_FLAKE_INPUTS}
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

          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;

              permittedInsecurePackages = [
                ${concatMapStrings (pkg: ''"${pkg}"'') (icedos.applications.insecurePackages or [])}
              ];
            };
          };

          inherit (pkgs) lib;
          inherit (lib) fileContents map filterAttrs;

          inherit (builtins) fromTOML pathExists;
          inherit ((fromTOML (fileContents "''${inputs.icedos-config}/config.toml"))) icedos;

          icedosLib = import "''${inputs.icedos-core}/lib" {
            inherit lib pkgs inputs;
            config = icedos;
            self = toString inputs.icedos-core;
          };

          inherit (icedosLib) modulesFromConfig;

          getModules =
            path:
            map (dir: "/''${path}/''${dir}") (
              let
                inherit (lib) attrNames;
              in
              attrNames (filterAttrs (n: v: v == "directory") (builtins.readDir path))
            );
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
                    default = "${ICEDOS_STATE_DIR}";
                  };
                }
              )

              # Symlink configuration state on "/run/current-system/source"
              {
                # Source: https://github.com/NixOS/nixpkgs/blob/5e4fbfb6b3de1aa2872b76d49fafc942626e2add/nixos/modules/system/activation/top-level.nix#L191
                system.systemBuilderCommands = "ln -s ''${self} $out/source";
              }

              {
                imports = [
                  "''${inputs.icedos-core}/modules/nh.nix"
                  "''${inputs.icedos-core}/modules/nix.nix"
                  "''${inputs.icedos-core}/modules/rebuild.nix"
                  "''${inputs.icedos-core}/modules/state.nix"
                  "''${inputs.icedos-core}/modules/toolset.nix"
                  "''${inputs.icedos-core}/modules/users.nix"
                ];
              }

              # Internal modules and config
              {
                imports = [ "''${inputs.icedos-core}/modules/options.nix" ] ++ (if (pathExists "''${inputs.icedos-config}/extra-modules") then (getModules "''${inputs.icedos-config}/extra-modules") else []);
                config.system.stateVersion = "${icedos.system.version}";
              }

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
