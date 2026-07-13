let
  inherit (builtins) toJSON;
  inherit (import ./load-user-config.nix ICEDOS_CONFIG_ROOT) icedos;

  system = icedos.system.arch or "x86_64-linux";
  pkgs = import <nixpkgs> { inherit system; };
  inherit (pkgs) lib;

  inherit (lib)
    all
    any
    boolToString
    collect
    concatMapStrings
    concatStringsSep
    elem
    evalModules
    fileContents
    filter
    flatten
    generators
    hasPrefix
    imap0
    isOption
    listToAttrs
    optional
    pathExists
    removePrefix
    showOption
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
    _loadModulesFromRepo
    _parseFlakeUrl
    injectIfExists
    mkInputName
    modulesFromConfig
    resolveExternalDependencyRecursively
    validate
    ;

  configRootKeep = [
    "flake.nix"
    "flake.lock"
    "config.toml"
    ".private.toml"
  ];

  # Patch files declared by `[[icedos.repositories]]` `patches`. They must
  # survive into the filtered config flake so the build stage can read them
  # from `inputs.icedos-config`: build-stage eval is pure and cannot reach the
  # host config root the way the impure genflake eval can.
  repoPatchKeep = flatten (
    map (r: (r.patches or [ ]) ++ map (ip: ip.patches or [ ]) (r.inputPatches or [ ])) (
      icedos.repositories or [ ]
    )
  );
  keepPatch = rel: any (pp: pp == rel || hasPrefix "${rel}/" pp) repoPatchKeep;

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
      || (hasPrefix "extra-modules/" relativePath)
      || (keepPatch relativePath);
  };

  channels = icedos.system.channels or [ ];
  isFirstBuild = !pathExists "/run/current-system/source" || (icedos.system.forceFirstBuild or false);

  # Whether to inline the host's /etc/nixos/hardware-configuration.nix into
  # the generated system. On by default so the machine's essentials
  # (filesystems, kernel modules, microcode, …) always apply; read raw here
  # since the injection decision happens at genflake stage. Mirrors the
  # `icedos.system.loadHardwareConfiguration` option default in modules/options.nix.
  loadHardwareConfiguration = icedos.system.loadHardwareConfiguration or true;

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

  evaluatedModules = evalModules {
    modules = [
      (import ../modules/options.nix {
        inherit icedosLib lib;
        inputs.icedos-config = ICEDOS_CONFIG_ROOT;
      })
    ]
    ++ modulesFromConfig.options;
  };

  evaluated = evaluatedModules.config;

  evaluatedConfig = toJSON evaluated;

  # Map an absolute declaration/source path to a stable repo-relative one.
  # Production evals resolve paths into /nix/store/<hash>-source/…; dev (path:
  # override) resolves them under the core root. Strip whichever applies so the
  # emitted pointer is usable against a repo checkout — and identical in both modes.
  repoRelative =
    p:
    let
      s = toString p;
      coreRoot = toString ./.. + "/";
      m = builtins.match "(.*/[a-z0-9]{32}-[^/]*/)(.*)" s;
    in
    if hasPrefix coreRoot s then
      removePrefix coreRoot s
    else if m != null then
      builtins.elemAt m 1
    else
      s;

  # Searchable index of every IceDOS option (path, type, description, current
  # value) — consumed by `icedos configuration show`. Reuses the same evalModules
  # as `evaluatedConfig`: type/description come from `.options`, the value from
  # `.config` (`evaluated`).
  optionsDoc =
    let
      # Walk the evaluated options tree with `collect isOption`, which treats
      # each option as a leaf and never expands submodule internals. This is
      # deliberate: `optionAttrSetToDocList` would recurse through
      # `getSubOptions`, and `toolsetCommandType` (commands → commands → …) is
      # infinitely self-recursive, overflowing the stack. The cost is that
      # submodule-list fields (users.<name>.*, repositories.*) aren't listed
      # individually; plain nested options (buildVm.memory, system.packages, …)
      # all are.
      opts = filter (
        o: (o.visible or true) && !(o.internal or false) && hasPrefix "icedos." (showOption o.loc)
      ) (collect isOption evaluatedModules.options);

      # The option's effective value: user override if set, else the resolved
      # default. Read from `evaluated` (the merged `.config`), not the raw
      # `.options` default. `tryEval` guards `throw`/`assert`-based defaults;
      # note it can NOT catch missing-attribute errors, so any default that
      # forces an absent input must be made presence-safe at its source (see
      # `cache.key` in modules/options.nix) or it aborts the whole index.
      renderValue =
        o:
        let
          r = builtins.tryEval (lib.attrByPath o.loc null evaluated);
        in
        if r.success then r.value else null;

      # Descriptions are plain strings on modern nixpkgs but may arrive as an
      # `{ _type = "mdDoc"; text; }` literal — normalise to a bare string.
      renderDescription =
        o:
        let
          d = o.description or null;
        in
        if builtins.isAttrs d then (d.text or null) else d;

      # Where the option is declared, as "<repo-relative-file>:<line>". Prefer
      # declarationPositions (carries line); fall back to declarations (file only).
      renderDeclaredAt =
        o:
        let
          positions = o.declarationPositions or [ ];
          decls = o.declarations or [ ];
        in
        if positions != [ ] then
          let
            pos = builtins.head positions;
          in
          if (pos.line or null) == null then
            repoRelative pos.file
          else
            "${repoRelative pos.file}:${toString pos.line}"
        else if decls != [ ] then
          repoRelative (builtins.head decls)
        else
          null;
    in
    toJSON (
      map (o: {
        name = showOption o.loc;
        type = o.type.description or "";
        description = renderDescription o;
        value = renderValue o;
        declaredAt = renderDeclaredAt o;
      }) opts
    );

  # Full module graph for `icedos modules`: every module available in every repo
  # that contributes a loaded module — configured *and* transitive dependency
  # repos — each flagged enabled (loaded) / explicit (user-listed) plus its
  # dependency edges, so disabled siblings show up next to the enabled ones.
  modulesDoc =
    let
      repos = icedos.repositories or [ ];

      # The loaded set: explicitly-enabled modules + their resolved deps. Used
      # to flag which catalog entries are active and to discover every repo in
      # play — each module's _repoInfo already carries the full file list.
      resolved = resolveExternalDependencyRecursively {
        newDeps = repos;
        loadOverrides = true;
      };

      moduleKey = m: "${m._repoInfo.url}/${m.meta.name}";
      loadedKeys = map moduleKey resolved.modules;

      # Every distinct fetched repo (deduped by url), configured *and* transitive.
      # `_repoInfo.files` is the complete module list, so re-loading it surfaces
      # disabled siblings (e.g. providers' jovian) with no extra fetch.
      # Extra-modules (url = "config") carry no `files`.
      realRepoInfos = builtins.attrValues (
        listToAttrs (
          map (ri: {
            name = ri.url;
            value = ri;
          }) (filter (ri: ri ? files) (map (m: m._repoInfo) resolved.modules))
        )
      );

      catalog = flatten (map _loadModulesFromRepo realRepoInfos);

      # Config-local extra modules have no catalog to enumerate; keep them as-is.
      extraModules = filter (m: !(m._repoInfo ? files)) resolved.modules;

      # Names the user explicitly enabled, keyed by repo baseUrl (== _repoInfo.url).
      explicitByRepo = listToAttrs (
        map (r: {
          name = (_parseFlakeUrl r.url).baseUrl;
          value = r.modules or [ ];
        }) repos
      );

      depEntry = d: { modules = d.modules or [ ]; };

      mkRecord = m: {
        inherit (m.meta) name;
        repo = m._repoInfo.url;
        description = m.meta.description or "";
        source = if m ? _sourceFile then repoRelative m._sourceFile else null;
        dependencies = map depEntry (m.meta.dependencies or [ ]);
        optionalDependencies = map depEntry (m.meta.optionalDependencies or [ ]);
        enabled = elem (moduleKey m) loadedKeys;
        explicit =
          (m.meta.name == "default") || elem m.meta.name (explicitByRepo.${m._repoInfo.url} or [ ]);
      };

      # Drop every `default` module: it's an always-on baseline aggregator (one
      # per repo), not a user-selectable module — its deps still appear as their
      # own entries.
      deduped = builtins.attrValues (
        listToAttrs (
          map (m: {
            name = moduleKey m;
            value = m;
          }) (filter (m: m.meta.name != "default") (catalog ++ extraModules))
        )
      );
    in
    toJSON (map mkRecord deduped);

  flakeInputsNix = generators.toPretty {
    multiline = true;
    allowPrettyValues = true;
  } flakeInputs;
in
{
  inherit
    evaluatedConfig
    flakeInputsNix
    optionsDoc
    modulesDoc
    ;

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
              (lib.setDefaultModuleLocation "config.toml / .private.toml (raw NixOS passthrough)" {
                config = builtins.removeAttrs userConfig [ "icedos" ];
              })

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

              ${lib.optionalString loadHardwareConfiguration (injectIfExists {
                file = "/etc/nixos/hardware-configuration.nix";
              })}
              ${injectIfExists { file = "/etc/nixos/extras.nix"; }}
            ]
            ++ modulesFromConfig.options
            ++ (modulesFromConfig.nixosModules { inherit inputs; });
          };
        };
    }
  '';
}
