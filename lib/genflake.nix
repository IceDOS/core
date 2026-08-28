let
  inherit (builtins) toJSON;
  userConfig = import ./config/load-user-config.nix ICEDOS_CONFIG_ROOT;
  inherit (userConfig) icedos;

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
    _repoSelected
    _selectedRepos
    injectIfExists
    mkInputName
    modulesFromConfig
    resolveExternalDependencyRecursively
    validate
    ;

  # `[extraOptions]` declares user options; their VALUES live at their real paths.
  # `inject` re-applies them here, where the build-stage passthrough doesn't run.
  extraSchema = userConfig.extraOptions or { };
  extraOptionsDeclare = icedosLib.extraOptions.declare extraSchema;
  extraOptionsInject = icedosLib.extraOptions.inject extraSchema userConfig;

  # Read raw (bootstrap path), mirroring the defaults in modules/options.nix.
  extraModulesDirs = icedos.system.extraModules or [ "modules" ];
  extraConfigsDirs = icedos.system.extraConfigs or [ "configs" ];

  configRootKeep = [
    "flake.nix"
    "flake.lock"
    "config.toml"
  ];

  # Anything an extra module imports must live in the kept set: genflake reads the
  # config root live, the build stage only this snapshot.
  configRootKeepDirs = extraModulesDirs ++ extraConfigsDirs;

  # Repo patch files must survive into the snapshot: build-stage eval is pure and
  # cannot reach the host config root.
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
      || (any (d: relativePath == d || hasPrefix "${d}/" relativePath) configRootKeepDirs)
      || (keepPatch relativePath);
  };

  channels = icedos.system.channels or [ ];

  # Catch a user-set `isFirstBuild` before evalModules turns it into nixpkgs'
  # generic readOnly error, and point at `forceFirstBuild` instead.
  isFirstBuildGuard = validate.abort {
    when = builtins.hasAttr "isFirstBuild" (icedos.system or { });
    path = "icedos.system.isFirstBuild";
    msg = "is framework-managed (readOnly); to force a first boot, set icedos.system.forceFirstBuild instead";
  };

  isFirstBuild = !pathExists "/run/current-system/source" || (icedos.system.forceFirstBuild or false);

  # Inline /etc/nixos/hardware-configuration.nix; read raw because the injection
  # decision happens here. Default mirrors modules/options.nix.
  loadHardwareConfiguration = icedos.system.loadHardwareConfiguration or true;

  # Each entry sets `channel` or `url` (`channel` wins). Validated here so the
  # user sees the offending entry, not a deep nix trace.
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

  # `if-then-raw` ties the (already-throwing) checks to the produced list.
  # Entries with empty `packages` are dropped as no-ops.
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

  # extraFlake names become root inputs, so a collision with a channel, overlay,
  # sub-flake or reserved name would silently overwrite in `listToAttrs` below.
  extraFlakeNameGuard = validate.abort {
    when =
      (lib.intersectLists (map (f: f.name or "") (icedos.system.extraFlakes or [ ])) (
        (map (c: c.name or "") channels)
        ++ (map (e: e.name) overlayInputs)
        ++ (builtins.attrNames modulesFromConfig.subFlakes)
        ++ [
          "nixpkgs"
          "home-manager"
          "icedos-config"
          "icedos-core"
          "icedos-state"
        ]
      )) != [ ];
    path = "icedos.system.extraFlakes";
    msg = "name collides with a [[icedos.system.channels]] name, an overlay input name, a module sub-flake name, or a genflake-reserved input name";
  };

  # --update-repos-select repos, validated against [[icedos.repositories]].
  configuredRepoInputNames = map (
    r: mkInputName { parts = [ (_parseFlakeUrl (r.url or "")).baseUrl ]; }
  ) (icedos.repositories or [ ]);

  updateReposSelectUnknown = filter (
    s: !(any (_repoSelected [ s ]) configuredRepoInputNames)
  ) _selectedRepos;

  updateReposSelectGuard = validate.abort {
    when = updateReposSelectUnknown != [ ];
    path = "--update-repos-select";
    msg = "unknown repo(s): ${concatStringsSep " " updateReposSelectUnknown} — only repos listed in [[icedos.repositories]] can be selected";
  };

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
      # No default (readOnly), so `toJSON evaluated` would throw without this.
      { icedos.system.isFirstBuild = isFirstBuild; }

      # Computed from the RAW config, so injecting it here cannot recurse.
      {
        icedos.system.loadedModules = modulesFromConfig.loadedModules;
      }
    ]
    ++ modulesFromConfig.options
    # Without the re-apply the genflake-stage eval would show null (the raw
    # passthrough only runs at build stage).
    ++ [ extraOptionsDeclare ]
    ++ extraOptionsInject;
  };

  evaluated = evaluatedModules.config;

  evaluatedConfig = toJSON evaluated;

  # Absolute declaration path -> repo-relative, identical in store and dev-path
  # evals, so the emitted pointer works against a checkout.
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

  # Option index for `icedos configuration search`: type/description from
  # `.options`, current value from the merged `.config`.
  optionsDoc =
    let
      # `collect isOption`, not `optionAttrSetToDocList`: the latter recurses into
      # submodules, and `toolsetCommandType` is infinitely self-recursive.

      # `tryEval` guards throwing defaults but NOT missing attributes — a default
      # forcing an absent input must be presence-safe at its source.
      renderValue =
        o:
        let
          r = builtins.tryEval (lib.attrByPath o.loc null evaluated);
        in
        if r.success then r.value else null;

      # Descriptions may arrive as an `{ _type = "mdDoc"; text; }` literal.
      renderDescription =
        o:
        let
          d = o.description or null;
        in
        if builtins.isAttrs d then (d.text or null) else d;

      # "<file>:<line>"; `declarations` (file only) is the fallback.
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

      # The marker lands in every `[extraOptions]`-declared option's `declarations`.
      isExtraOption = o: lib.elem icedosLib.extraOptions.marker (o.declarations or [ ]);
    in
    toJSON (
      map
        (o: {
          name = showOption o.loc;
          type = o.type.description or "";
          description = renderDescription o;
          value = renderValue o;
          declaredAt = renderDeclaredAt o;
        })
        (
          filter (
            o:
            (o.visible or true)
            && !(o.internal or false)
            && (hasPrefix "icedos." (showOption o.loc) || isExtraOption o)
          ) (collect isOption evaluatedModules.options)
        )
    );

  # Module graph for `icedos modules`: every module of every contributing repo,
  # flagged enabled/explicit with its dependency edges.
  modulesDoc =
    let
      repos = icedos.repositories or [ ];

      # Enabled modules + resolved deps; also how every repo in play is discovered.
      resolved = resolveExternalDependencyRecursively {
        newDeps = repos;
        loadOverrides = true;
      };

      moduleKey = m: "${m._repoInfo.url}/${m.meta.name}";
      loadedKeys = map moduleKey resolved.modules;

      # `_repoInfo.files` is the complete module list, so disabled siblings surface
      # with no extra fetch. Extra modules (url = "config") carry no `files`.
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

      # `default` is an always-on aggregator, not a user-selectable module.
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

  # The complete merged config set for the webui, not just config.toml.
  userConfigRaw = toJSON userConfig;

  # Sub-flake texts leave this stage only as the root inputs' store paths; nothing
  # else is exported (the build orchestrator reads the resulting flake.lock).

  # Literal tokens end up inside the world-readable wrapper derivation, so every
  # eval of this stage warns while one is configured.
  githubTokenStoreWarning =
    if (icedos.system.githubToken or "") != "" then
      builtins.trace "warning: icedos.system.githubToken is embedded in the nix store (world-readable to every local user); prefer a token file via icedos.system.githubTokenPath" true
    else
      true;
in
assert isFirstBuildGuard;
assert extraFlakeNameGuard;
assert updateReposSelectGuard;
assert githubTokenStoreWarning;
{
  inherit
    evaluatedConfig
    flakeInputsNix
    optionsDoc
    modulesDoc
    userConfigRaw
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
          userConfig = import "''${inputs.icedos-core}/lib/config/load-user-config.nix" "''${inputs.icedos-config}";
          inherit (userConfig) icedos;

          icedosLib = import "''${inputs.icedos-core}/lib" {
            inherit lib pkgs inputs;
            config = icedos;
            enableLogging = ${boolToString icedosLib.ENABLE_LOGGING};
            self = toString inputs.icedos-core;
          };

          inherit (icedosLib) getModules modulesFromConfig;

          # Re-derived, not interpolated: this stage reads the filtered snapshot.
          extraOptionsDeclare = icedosLib.extraOptions.declare (userConfig.extraOptions or { });
        in {
          # The same value `specialArgs.icedosLib` gets, so repl-context and MCP
          # `nix_eval` read the lib the module system actually used.
          icedosLib = modulesFromConfig.closureLib;

          nixosConfigurations.icedos = nixpkgs.lib.nixosSystem rec {
            specialArgs = {
              # Reused (not re-merged), so module files and the module system share
              # one lib. Genflake-side uses below keep the base `icedosLib`.
              icedosLib = modulesFromConfig.closureLib;
              inherit inputs;
            };

            modules = [
              # Read configuration location
              (
                { icedosLib, ... }:
                let
                  inherit (icedosLib) mkStrOption;
                in
                {
                  # config.toml values already abort at genflake ("option does not
                  # exist"); readOnly guards module-set values at build stage.
                  options.icedos.configurationLocation = mkStrOption {
                    readOnly = true;
                    default = "${ICEDOS_STATE_DIR}";
                  };
                }
              )

              # Remove nixos manual package
              {
                documentation.nixos.enable = false;
              }

              # repo url -> names, computed from the RAW config (no circularity).
              # Backs `icedosLib.hasModule`.
              {
                icedos.system.loadedModules = modulesFromConfig.loadedModules;
              }

              {
                imports = getModules "''${inputs.icedos-core}/modules";
              }

              # Extra modules and stateVersion; missing dirs are skipped.
              {
                imports = lib.flatten (map (
                  d:
                  let
                    p = "''${inputs.icedos-config}/''${d}";
                  in
                  if pathExists p then getModules p else [ ]
                ) ${builtins.toJSON extraModulesDirs});
                config.system.stateVersion = "${icedos.system.version}";
              }

              # Every top-level table except [icedos.*] is applied verbatim as NixOS
              # config; `extraOptions` is a schema, not values, so it is excluded.
              (lib.setDefaultModuleLocation "config.toml / configs/*.toml (raw NixOS passthrough)" {
                config = builtins.removeAttrs userConfig [ "icedos" "extraOptions" ];
              })

              extraOptionsDeclare

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
                      # Head of the list, so the source swap runs BEFORE downstream
                      # `overrideAttrs` patch overlays it would otherwise clobber.
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
