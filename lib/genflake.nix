let
  inherit (builtins) readFile toJSON;
  inherit (fromTOML (readFile "${ICEDOS_CONFIG_ROOT}/config.toml")) icedos;

  system = icedos.system.arch or "x86_64-linux";
  pkgs = import <nixpkgs> { inherit system; };
  inherit (pkgs) lib writeText;

  inherit (lib)
    all
    boolToString
    concatMapStrings
    concatStringsSep
    evalModules
    fileContents
    filter
    generators
    imap0
    listToAttrs
    optional
    pathExists
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
    mkInputName
    modulesFromConfig
    validate
    ;

  channels = icedos.system.channels or [ ];
  isFirstBuild = !pathExists "/run/current-system/source" || (icedos.system.forceFirstBuild or false);

  # `[[icedos.system.overlays.fromChannel]]` entries. Each must set either
  # `channel` (existing `[[icedos.system.channels]]` name) or `url` (flake
  # URL — registered as `icedos-overlay-<sanitized-url>`); `channel` wins
  # when both are set. Validation aborts here with rich path messages so
  # users see the offending entry, not a deep nix trace.
  overlayChannelsRaw = icedos.system.overlays.fromChannel or [ ];

  # Read raw TOML — missing fields default to "" / [] so validation messages
  # can pinpoint the offending entry rather than trip over a hard attr-miss.
  overlayEntry = e: {
    channel = e.channel or "";
    packages = e.packages or [ ];
    url = e.url or "";
  };

  overlayCheck =
    idx: e:
    validate.abort {
      when = e.url == "" && e.channel == "";
      path = "icedos.system.overlays.fromChannel[${toString idx}]";
      msg = "must set either 'channel' (existing [[icedos.system.channels]] name) or 'url' (flake URL)";
    }
    && validate.abort {
      when = e.packages == [ ];
      path = "icedos.system.overlays.fromChannel[${toString idx}]";
      msg = "'packages' must be non-empty (an overlay with no packages is a no-op)";
    };

  # Force every check; failures already threw. `if-then-raw` keeps the second
  # branch unreachable but ties the validation result to the produced list.
  overlayChannels =
    let
      normalised = map overlayEntry overlayChannelsRaw;
    in
    if all (x: x) (imap0 overlayCheck normalised) then normalised else normalised;

  isOverlayUrlMode = e: e.channel == "" && e.url != "";

  overlayInputs = map (e: {
    name = mkInputName {
      parts = [
        "overlay"
        e.url
      ];
    };

    value = { inherit (e) url; };
  }) (filter isOverlayUrlMode overlayChannels);

  nixpkgsInput = {
    name = "nixpkgs";

    value = {
      url = icedos.system.nixpkgsChannel or "github:nixos/nixpkgs/nixos-unstable";
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
    ++ overlayInputs
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
          { config = { inherit icedos; }; }
          (import ../modules/options.nix {
            inherit icedosLib lib;
            inputs.icedos-config = ICEDOS_CONFIG_ROOT;
          })
        ]
        ++ modulesFromConfig.options;
      }).config;
in
{
  inherit evaluatedConfig;

  flakeInputsNix = generators.toPretty {
    multiline = true;
    allowPrettyValues = true;
  } flakeInputs;

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
                ${concatMapStrings (pkg: ''"${pkg}"'') (icedos.applications.insecurePackages or [ ])}
              ];
            };
          };

          inherit (pkgs) lib;
          inherit (lib) fileContents filterAttrs;

          inherit (builtins) pathExists;
          inherit ((fromTOML (fileContents "''${inputs.icedos-config}/config.toml"))) icedos;

          icedosLib = import "''${inputs.icedos-core}/lib" {
            inherit lib pkgs inputs;
            config = icedos;
            self = toString inputs.icedos-core;
          };

          inherit (icedosLib) modulesFromConfig;

          getModules =
            path:
            let
              inherit (lib) attrNames;
              dirs = attrNames (filterAttrs (n: v: v == "directory") (builtins.readDir path));
              hasDefaultNix = dir: pathExists "''${path}/''${dir}/default.nix";
            in
            map (dir: "/''${path}/''${dir}") (builtins.filter hasDefaultNix dirs);
        in {
          nixosConfigurations."${fileContents "/etc/hostname"}" = nixpkgs.lib.nixosSystem rec {
            specialArgs = {
              inherit icedosLib inputs;
            };

            modules = [
              # Read configuration location
              (
                { icedosLib, ... }:
                let
                  inherit (icedosLib) mkStrOption;
                in
                {
                  options.icedos.configurationLocation = mkStrOption {
                    default = "${ICEDOS_STATE_DIR}";
                  };
                }
              )

              # Symlink configuration state on "/run/current-system/source"
              {
                # Source: https://github.com/NixOS/nixpkgs/blob/5e4fbfb6b3de1aa2872b76d49fafc942626e2add/nixos/modules/system/activation/top-level.nix#L191
                system.systemBuilderCommands = "ln -s ''${self} $out/source";
              }

              # Remove nixos manual package
              {
                documentation.nixos.enable = false;
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

              ${concatMapStrings (
                e:
                let
                  target =
                    if e.channel != "" then
                      ''"${e.channel}"''
                    else
                      ''inputs."${
                        mkInputName {
                          parts = [
                            "overlay"
                            e.url
                          ];
                        }
                      }"'';

                  pkgList = concatMapStrings (p: ''"${p}" '') e.packages;
                in
                ''
                  (
                    { lib, ... }: {
                      # `lib.mkBefore` keeps these overlays at the head of
                      # `nixpkgs.overlays` so they swap the package source
                      # *before* downstream patch overlays (e.g. cosmic
                      # patches) run via `prev.<pkg>.overrideAttrs`. Without
                      # it the swap clobbers patches that already landed on
                      # the base derivation.
                      nixpkgs.overlays = lib.mkBefore (icedosLib.pkgs.overlaysFromChannel ${target} [ ${pkgList} ]);
                    }
                  )
                ''
              ) overlayChannels}

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
