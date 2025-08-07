let
  inherit (builtins)
    readFile
    toFile
    toJSON
    ;

  inherit (pkgs)
    bash
    coreutils
    gnused
    lib
    nix
    nixfmt-rfc-style
    ;

  inherit (lib)
    attrNames
    boolToString
    concatImapStrings
    fileContents
    map
    pathExists
    ;

  system = "x86_64-linux";
  cfg = (fromTOML (fileContents ./config.toml)).icedos;
  pkgs = import <nixpkgs> { inherit system; };

  icedosLib = import ./lib.nix {
    inherit lib pkgs;
    config = cfg;
    self = ./.;
  };

  aagl = cfg.applications.aagl;
  channels = cfg.system.channels;

  chaotic = (
    graphics.mesa.unstable
    || cfg.system.kernel == "cachyos"
    || cfg.system.kernel == "cachyos-rc"
    || cfg.system.kernel == "cachyos-server"
    || cfg.system.kernel == "valve"
    || steam-session
  );

  configurationLocation = fileContents "/tmp/configuration-location";
  gnome = cfg.desktop.gnome.enable;
  graphics = cfg.hardware.graphics;
  hyprland = cfg.desktop.hyprland.enable;
  isFirstBuild = !pathExists "/run/current-system/source" || cfg.system.forceFirstBuild;
  librewolf = cfg.applications.librewolf;
  ryzen = cfg.hardware.cpus.ryzen.enable;
  server = cfg.hardware.devices.server;
  steam-session = cfg.applications.steam.session.enable;
  users = attrNames cfg.system.users;
  zen-browser = cfg.applications.zen-browser.enable;

  externalModulesOutputs =
    map
    icedosLib.getExternalModuleOutputs
    cfg.externalModuleRepositories;

  extraInputs = icedosLib.serializeAllExternalInputs externalModulesOutputs;
in
{
  flake.nix = ''
    {
      inputs = {
        # Package repositories
        ${
          if (chaotic) then
            ''
              chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
            ''
          else
            ""
        }

        nixpkgs.${
          if (chaotic) then
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
            if (chaotic) then
              ''
                follows = "chaotic/home-manager";
              ''
            else
              ''
                inputs.nixpkgs.follows = "nixpkgs";
              ''
          }
        };

        nerivations = {
          url = "github:icedborn/nerivations";
          inputs.nixpkgs.follows = "nixpkgs";
        };

        ${
          if (cfg.system.kernel == "valve" || steam-session) then
            ''
              steam-session.follows = "chaotic/jovian";
            ''
          else
            ""
        }

        # Apps
        ${
          if (aagl) then
            ''
              aagl = {
                url = "github:ezKEa/aagl-gtk-on-nix";
                inputs.nixpkgs.follows = "nixpkgs";
              };
            ''
          else
            ""
        }

        ${
          if (librewolf) then
            ''
              pipewire-screenaudio = {
                url = "github:IceDBorn/pipewire-screenaudio";
                inputs.nixpkgs.follows = "nixpkgs";
              };
            ''
          else
            ""
        }

        ${
          if (zen-browser) then
            ''
              zen-browser = {
                url = "github:0xc000022070/zen-browser-flake";
                inputs.nixpkgs.follows = "nixpkgs";
              };
            ''
          else
            ""
        }

        ${extraInputs}
      };

      outputs =
        {
          home-manager,
          nerivations,
          nixpkgs,
          self,
          ${if (aagl) then ''aagl,'' else ""}
          ${if (chaotic) then ''chaotic,'' else ""}
          ${if (librewolf) then ''pipewire-screenaudio,'' else ""}
          ${if (steam-session) then ''steam-session,'' else ""}
          ${if (zen-browser) then ''zen-browser,'' else ""}
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
            inherit lib pkgs;
            config = cfg;
            self = ./.;
          };

          externalModulesOutputs =
            map
            icedosLib.getExternalModuleOutputs
            cfg.externalModuleRepositories;

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
                      attrNames (
                        filterAttrs (
                          n: v:
                          v == "directory" && !(n == "desktop" && path == ./system)) (
                          builtins.readDir path
                        )
                      )
                    );
                in
                {
                  imports = [
                    ./hardware
                    ./internals.nix
                    ./options.nix
                    ${if (ryzen) then "./hardware/cpus/modules/ryzen" else ""}
                  ]
                  ++ getModules (./hardware)
                  ++ getModules (./system)
                  ++ getModules(./.private);

                  config.system.stateVersion = "${cfg.system.version}";
                }
              )

              # External modules
              ${
                if (chaotic) then
                  ''
                    chaotic.nixosModules.default
                    ./hardware/graphics/modules/mesa
                  ''
                else
                  ""
              }

              home-manager.nixosModules.home-manager
              nerivations.nixosModules.default

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

              ${
                if (!server) then
                  ''
                    ./system/desktop
                  ''
                else
                  ""
              }

              # Is First Build
              { icedos.internals.isFirstBuild = ${boolToString (isFirstBuild)}; }

              ${
                if (steam-session && !isFirstBuild) then
                  ''
                    steam-session.nixosModules.default
                    ./system/desktop/steam-session
                  ''
                else
                  ""
              }

              ${
                if (aagl) then
                  ''
                    aagl.nixosModules.default
                    {
                      nix.settings = aagl.nixConfig; # Set up Cachix
                      programs.anime-game-launcher.enable = true; # Adds launcher and /etc/hosts rules
                    }
                  ''
                else
                  ""
              }

              ${
                if (hyprland) then
                  ''
                    ./system/desktop/hyprland
                  ''
                else
                  ""
              }

              ${
                if (gnome) then
                  ''
                    ./system/desktop/gnome
                  ''
                else
                  ""
              }

              ${if (zen-browser) then "./system/applications/modules/zen-browser" else ""}

              ${concatImapStrings (
                i: user:
                if (pathExists "${configurationLocation}/system/users/${user}") then
                  "./system/users/${user}\n"
                else
                  ""
              ) users}

              ${icedosLib.injectIfExists { file = "/etc/nixos/hardware-configuration.nix"; }}
              ${icedosLib.injectIfExists { file = "/etc/nixos/extras.nix"; }}
            ] ++ extraOptions ++ extraNixosModules;
          };
        };
    }
  '';
}
