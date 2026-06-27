let
  inherit (builtins) toJSON;
  inherit (import ./load-user-config.nix ICEDOS_CONFIG_ROOT) icedos;

  system = icedos.system.arch or "x86_64-linux";
  pkgs = import <nixpkgs> { inherit system; };
  inherit (pkgs) lib;

  inherit (lib)
    all
    boolToString
    concatMapStrings
    concatStringsSep
    elem
    evalModules
    fileContents
    filter
    generators
    hasPrefix
    imap0
    listToAttrs
    optional
    pathExists
    removePrefix
    ;

  icedosLib = import ../lib {
    inherit lib pkgs;
    config = icedos;
    self = ./..;
    inputs = { };
  };

  inherit (icedosLib)
    ICEDOS_CONFIG_ROOT
    ICEDOS_STATE_DIR
    injectIfExists
    mkInputName
    modulesFromConfig
    validate
    ;

  configRootKeep = [
    "flake.nix"
    "flake.lock"
    "config.toml"
    ".private.toml"
  ];

  filteredConfigRoot = builtins.path {
    name = "icedos-config";
    path = /. + ICEDOS_CONFIG_ROOT;

    filter =
      path: _:
      let
        relativePath = removePrefix "${ICEDOS_CONFIG_ROOT}/" path;
      in
      (elem relativePath configRootKeep)
      || (relativePath == "extra-modules")
      || (hasPrefix "extra-modules/" relativePath);
  };

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
    };

  # Force every check; failures already threw. `if-then-raw` keeps the second
  # branch unreachable but ties the validation result to the produced list.
  # Entries with empty `packages` are silently dropped (no-op overlay).
  overlayChannels =
    let
      normalised = map overlayEntry overlayChannelsRaw;
      nonEmpty = filter (e: e.packages != [ ]) normalised;
    in
    if all (x: x) (imap0 overlayCheck normalised) then nonEmpty else nonEmpty;

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
          url = "path:${filteredConfigRoot}";
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

  evaluated =
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

  evaluatedConfig = toJSON evaluated;

  flakeInputsNix = generators.toPretty {
    multiline = true;
    allowPrettyValues = true;
  } flakeInputs;
in
{
  inherit evaluatedConfig flakeInputsNix;

  flakeFinal = ''
    {
      inputs = ${flakeInputsNix};

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
            config = ${
              generators.toPretty {
                multiline = true;
                allowPrettyValues = true;
              } (icedosLib.pkgs.mkConfig evaluated.icedos)
            };
          };

          inherit (pkgs) lib;
          inherit (builtins) pathExists;
          userConfig = import "''${inputs.icedos-core}/lib/load-user-config.nix" "''${inputs.icedos-config}";
          inherit (userConfig) icedos;

          icedosLib = import "''${inputs.icedos-core}/lib" {
            inherit lib pkgs inputs;
            config = icedos;
            self = toString inputs.icedos-core;
          };

          inherit (icedosLib) getModules modulesFromConfig;
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

              # Remove nixos manual package
              {
                documentation.nixos.enable = false;
              }

              {
                imports = getModules "''${inputs.icedos-core}/modules";
              }

              # Extra modules and stateVersion
              {
                imports = if (pathExists "''${inputs.icedos-config}/extra-modules") then (getModules "''${inputs.icedos-config}/extra-modules") else [];
                config.system.stateVersion = "${icedos.system.version}";
              }

              # Raw NixOS config passthrough: every top-level table in
              # config.toml / .private.toml *except* [icedos.*] is applied verbatim
              # as NixOS config. nixpkgs' module system types & validates each option —
              # IceDOS declares no schema. (home-manager is reachable the usual way,
              # under [home-manager.users.<name>.*].)
              {
                _file = "config.toml / .private.toml (raw NixOS passthrough)";
                config = builtins.removeAttrs userConfig [ "icedos" ];
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
                    { config, lib, ... }: {
                      # `lib.mkBefore` keeps these overlays at the head of
                      # `nixpkgs.overlays` so they swap the package source
                      # *before* downstream patch overlays (e.g. cosmic
                      # patches) run via `prev.<pkg>.overrideAttrs`. Without
                      # it the swap clobbers patches that already landed on
                      # the base derivation.
                      nixpkgs.overlays = lib.mkBefore (icedosLib.pkgs.overlaysFromChannel config.icedos ${target} [ ${pkgList} ]);
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
