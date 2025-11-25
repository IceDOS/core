let
  inherit (builtins) getEnv readFile;
  inherit ((fromTOML (readFile ../config.toml))) icedos;

  system = icedos.system.arch or "x86_64-linux";
  pkgs = import <nixpkgs> { inherit system; };
  inherit (pkgs) lib;

  inherit (lib)
    boolToString
    concatMapStrings
    concatStringsSep
    fileContents
    listToAttrs
    map
    pathExists
    ;

  icedosLib = import ../lib {
    inherit lib pkgs;
    config = icedos;
    self = ./.;
    inputs = { };
  };

  inherit (icedosLib) injectIfExists modulesFromConfig;

  channels = icedos.system.channels or [ ];
  configurationLocation = fileContents "/tmp/icedos/configuration-location";
  isFirstBuild = !pathExists "/run/current-system/source" || (icedos.system.forceFirstBuild or false);

  extraModulesInputs = modulesFromConfig.inputs;
  flakeInputs = listToAttrs extraModulesInputs;
  nixosModulesText = modulesFromConfig.nixosModulesText;
in
{
  inherit flakeInputs;

  flakeFinal = ''
    {
      inputs = {
        ${fileContents (getEnv "ICEDOS_FLAKE_INPUTS")}
        ${concatMapStrings (channel: ''"${channel.name}".url = ${channel.url};''\n'') channels}
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
