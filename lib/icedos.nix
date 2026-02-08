{
  config,
  icedosLib,
  inputs,
  lib,
  self,
  ...
}:

let
  inherit (builtins)
    hasAttr
    pathExists
    readFile
    replaceStrings
    ;

  inherit (lib)
    elem
    filter
    flatten
    hasAttrByPath
    ;

  inherit (icedosLib)
    ICEDOS_CONFIG_ROOT
    ICEDOS_STAGE
    INPUTS_PREFIX
    filterByAttrs
    findFirst
    flatMap
    stringStartsWith
    ;

  finalIcedosLib = icedosLib // rec {
    inputIsOverride = { input }: (hasAttr "override" input) && input.override;

    # Generate a sanitized full submodule name from URL and submodule name
    # Replaces special characters with underscores for avoiding flake registry warnings and errors
    getFullSubmoduleName =
      {
        url,
        subMod ? null,
      }:
      replaceStrings [ ":" "/" "." "?" "=" ] [ "_" "_" "_" "_" "_" ] (
        if subMod == null then "${INPUTS_PREFIX}-${url}" else "${INPUTS_PREFIX}-${url}-${subMod}"
      );

    _readFlakeLock = readFile "${self}/flake.lock" |> builtins.fromJSON;

    # Determine the revision suffix from flake.lock based on repo name
    # Returns either /{rev}, ?narHash={hash}, or empty string
    _getRevisionFromLock =
      {
        repoName,
        lock,
      }:
      let
        hasRev = hasAttrByPath [ "nodes" repoName "locked" "rev" ] lock;
        hasNarHash = hasAttrByPath [ "nodes" repoName "locked" "narHash" ] lock;
      in
      if (builtins.getEnv "ICEDOS_UPDATE" == "1") || (!hasRev && !hasNarHash) then
        ""
      else if hasRev then
        "/${lock.nodes.${repoName}.locked.rev}"
      else
        "?narHash=${lock.nodes.${repoName}.locked.narHash}";

    # Get the flake revision string (with / or ? prefix if available)
    _resolveFlakeRevision =
      {
        url,
        repoName,
      }:
      if (!(pathExists "${self}/flake.lock")) || ((stringStartsWith "path:" url) && (ICEDOS_STAGE == "genflake")) then
        ""
      else
        _getRevisionFromLock {
          inherit repoName;
          lock = _readFlakeLock;
        };

    # Fetch a modules repository, resolving the URL and loading its icedos modules
    # Handles overrides, flake resolution, and module file loading
    fetchModulesRepository =
      {
        url,
        overrides,
        ...
      }:
      let
        inherit (builtins) getFlake;
        inherit (lib) optionalAttrs;

        # Apply override URL if available
        _url = if (hasAttr url overrides) then overrides.${url} else url;
        repoName = getFullSubmoduleName { url = _url; };

        # Resolve the flake revision from lock file
        flakeRev = _resolveFlakeRevision {
          url = _url;
          inherit repoName;
        };

        # Build complete flake URL with revision
        flakeUrl = "${_url}${flakeRev}";

        # Load the flake (either fresh or from inputs)
        flake = if (ICEDOS_STAGE == "genflake") then (getFlake flakeUrl) else inputs.${repoName};

        # Extract icedos modules from the flake
        modules = flake.icedosModules { icedosLib = finalIcedosLib; };
      in
      {
        url = _url;
        inherit (flake) narHash;
        files = flatten modules;
      }
      // (optionalAttrs (hasAttr "rev" flake) { inherit (flake) rev; });

    # Convert external modules into flake input declarations
    # Filters out modules marked to skip as inputs
    _modulesToInputs =
      modules:
      let
        inherit (builtins) filter;
        shouldIncludeAsInput =
          mod: !(hasAttr "skipModuleAsInput" mod._repoInfo && mod._repoInfo.skipModuleAsInput);
      in
      map (
        { _repoInfo, ... }:
        let
          inherit (_repoInfo) url;
          flakeRev =
            if (hasAttr "rev" _repoInfo) then
              "/${_repoInfo.rev}"
            else if (hasAttr "narHash" _repoInfo) then
              "?narHash=${_repoInfo.narHash}"
            else
              "";
        in
        {
          name = getFullSubmoduleName { inherit url; };
          value = {
            url = "${url}${flakeRev}";
          };
        }
      ) (filter shouldIncludeAsInput modules);

    # Extract input dependencies from modules and create properly namespaced input declarations
    # Handles override inputs separately to preserve their names
    _getModuleInputs =
      modules:
      let
        inherit (builtins) attrNames filter;
        modulesWithInputs = filter (hasAttr "inputs") modules;
      in
      flatten (
        map (
          {
            _repoInfo,
            inputs,
            meta,
            ...
          }:
          map (
            i:
            let
              isOverride = inputIsOverride { input = inputs.${i}; };
              moduleIdentifier =
                if (hasAttr "skipModuleAsInput" _repoInfo && _repoInfo.skipModuleAsInput) then
                  "icedos-config"
                else
                  getFullSubmoduleName {
                    inherit (_repoInfo) url;
                    subMod = meta.name;
                  };
            in
            {
              _originalName = i;
              name = if isOverride then i else "${moduleIdentifier}-${i}";
              value = removeAttrs inputs.${i} [ "override" ];
            }
          ) (attrNames inputs)
        ) modulesWithInputs
      );

    # Create a masked inputs set for nixos module evaluation
    # Ensures modules use consistent input names and see appropriate dependencies
    _createMaskedInputs =
      {
        baseInputs,
        moduleInputs,
        repoInfo,
        isSkipModuleAsInput,
      }:
      {
        inherit (baseInputs) nixpkgs home-manager;
        icedos-state = if (hasAttr "icedos-state" baseInputs) then baseInputs.icedos-state else null;

        self =
          if isSkipModuleAsInput then
            "icedos-config"
          else
            baseInputs.${getFullSubmoduleName { url = repoInfo.url; }};
      }
      // (
        let
          inherit (builtins) listToAttrs;
        in
        listToAttrs (
          map (i: {
            name = i._originalName;
            value = baseInputs.${i.name};
          }) moduleInputs
        )
      );

    # Extract all options declarations from modules that define them
    _getModuleOptions =
      modules:
      map (
        { options, ... }:
        {
          inherit options;
        }
      ) (filterByAttrs [ "options" ] modules);

    # Process output modules into nixos modules with proper input masking
    # Each module's outputs are evaluated with its appropriate input set
    _extractNixosModules =
      {
        inputs,
        modules,
      }:
      let
        inherit (lib) flatten;

        moduleInputs = _getModuleInputs modules;

        processModuleOutputs =
          { inputs, ... }:
          { _repoInfo, outputs, ... }:
          let
            maskedInputs = _createMaskedInputs {
              baseInputs = inputs;
              inherit moduleInputs;
              repoInfo = _repoInfo;
              isSkipModuleAsInput = hasAttr "skipModuleAsInput" _repoInfo && _repoInfo.skipModuleAsInput;
            };
          in
          outputs.nixosModules { inputs = maskedInputs; };
      in
      flatten (
        map (processModuleOutputs { inherit inputs; }) (filterByAttrs [ "outputs" "nixosModules" ] modules)
      );

    # Main function to extract all outputs from external modules
    # Combines inputs, nixos modules, options, and module text outputs
    getExternalModuleOutputs =
      modules:
      let
        inherit (lib) flatten;

        modulesAsInputs = _modulesToInputs modules;
        moduleInputs = _getModuleInputs modules;
        options = _getModuleOptions modules;

        nixosModules =
          params:
          _extractNixosModules {
            inputs = params.inputs;
            inherit modules;
          };

        nixosModulesText = flatten (
          map (mod: mod.outputs.nixosModulesText) (filterByAttrs [ "outputs" "nixosModulesText" ] modules)
        );
      in
      {
        inputs = modulesAsInputs ++ moduleInputs;

        inherit
          nixosModules
          nixosModulesText
          options
          ;
      };

    # Generate a unique key for a module (url/name combination)
    _getModuleKey = url: name: "${url}/${name}";

    # Build a set of override URL mappings from dependencies that define overrides
    _buildOverridesMap =
      {
        newDeps,
        loadOverrides,
        existingOverrides,
      }:
      let
        inherit (builtins) filter listToAttrs;
        filteredDeps = filter (hasAttr "overrideUrl") newDeps;
      in
      if loadOverrides then
        listToAttrs (
          map (dep: {
            name = dep.url;
            value = dep.overrideUrl;
          }) filteredDeps
        )
      else
        existingOverrides;

    # Load module files from a repository and ensure a default module exists
    # Returns list of modules with _repoInfo attached to each
    _loadModulesFromRepo =
      repo:
      let
        modules = map (
          f:
          {
            _repoInfo = repo;
          }
          // import f {
            inherit config lib;
            icedosLib = finalIcedosLib;
          }
        ) repo.files;

        hasDefault = findFirst (mod: mod.meta.name == "default") modules != null;
      in
      if hasDefault then
        modules
      else
        modules
        ++ [
          {
            _repoInfo = repo;
            meta.name = "default";
          }
        ];

    # Check if a module is already loaded (by key)
    _isModuleLoaded =
      existingDeps: url: name:
      elem (_getModuleKey url name) existingDeps;

    # Filter new modules to only include those that are needed and not already loaded
    _filterNewModules =
      {
        modules,
        existingDeps,
        requestedNames,
      }:
      let
        inherit (builtins) filter;

        isRequested = mod: (mod.meta.name == "default") || (elem mod.meta.name requestedNames);
        isNew = mod: !_isModuleLoaded existingDeps mod._repoInfo.url mod.meta.name;
      in
      filter (mod: isRequested mod && isNew mod) modules;

    # Extract internal dependencies from a module's metadata
    # Optionally includes optional dependencies based on flag
    _getModuleDependencies =
      {
        mod,
        fetchOptionalDependencies,
      }:
      let
        inherit (mod) meta;
        baseDeps = meta.dependencies or [ ];
        optionalDeps = if fetchOptionalDependencies then (meta.optionalDependencies or [ ]) else [ ];
      in
      baseDeps ++ optionalDeps;

    # Convert dependency metadata to resolved dependency entries (filtering already-loaded modules)
    _resolveDependencyEntries =
      {
        deps,
        sourceUrl,
        allKnownKeys,
      }:
      map (
        {
          url ? sourceUrl,
          modules ? [ ],
        }:
        let
          realUrl = if (url == "self") then sourceUrl else url;
        in
        {
          url = realUrl;
          modules = filter (mod: !elem (_getModuleKey realUrl mod) allKnownKeys) modules;
        }
      ) deps;

    # Recursively resolve external dependencies, fetching repositories and extracting modules
    # Handles deduplication and override merging across the entire dependency tree
    resolveExternalDependencyRecursively =
      {
        newDeps,
        existingDeps ? [ ],
        existingOverrides ? [ ],
        loadOverrides ? false,
      }:
      let
        inherit (builtins)
          filter
          foldl'
          length
          ;

        inherit (lib) optional unique;

        # Build override map from new dependencies or use existing
        overrides = _buildOverridesMap {
          inherit newDeps loadOverrides existingOverrides;
        };

        # Process each dependency and accumulate results
        result = foldl' (
          acc: newDep:
          let
            # Determine which modules are not yet loaded
            missingModules = filter (mod: !_isModuleLoaded existingDeps newDep.url mod) (newDep.modules or [ ]);

            # Fetch repository if new modules are needed or default isn't loaded
            newRepo = optional (
              ((length missingModules) > 0) || !_isModuleLoaded existingDeps newDep.url "default"
            ) (fetchModulesRepository (newDep // { inherit overrides; }));

            # Load and filter modules from the repository
            newModules = _filterNewModules {
              modules = flatMap _loadModulesFromRepo newRepo;
              existingDeps = existingDeps;
              requestedNames = newDep.modules or [ ];
            };

            # Build set of all known module keys (existing + new)
            newModulesKeys = map (mod: _getModuleKey mod._repoInfo.url mod.meta.name) newModules;
            allKnownKeys = unique (existingDeps ++ newModulesKeys);

            # Extract and resolve nested dependencies from new modules
            innerDeps = flatMap (
              mod:
              _resolveDependencyEntries {
                deps = _getModuleDependencies {
                  inherit mod;
                  fetchOptionalDependencies = newDep.fetchOptionalDependencies or false;
                };
                sourceUrl = newDep.url;
                inherit allKnownKeys;
              }
            ) newModules;

            # Recursively resolve inner dependencies if any
            resolvedInnerDeps = optional ((length innerDeps) > 0) (resolveExternalDependencyRecursively {
              newDeps = innerDeps;
              existingDeps = allKnownKeys;
              existingOverrides = overrides;
            });
          in
          flatten (acc ++ newModules ++ resolvedInnerDeps)
        ) [ ] newDeps;
      in
      result;

    # Import an extra module file and attach repository info
    # Extra modules are stored locally in the config directory
    _importExtraModule =
      {
        filePath,
        narHash,
      }:
      (import filePath { icedosLib = finalIcedosLib; })
      // {
        _repoInfo = {
          inherit narHash;
          url = "path:${filePath}";
          skipModuleAsInput = true;
        };
        meta.name = filePath;
      };

    # Load all extra modules from the config's extra-modules directory
    # Returns empty list if no extra modules directory exists
    _loadExtraModules =
      {
        configFlake,
        narHash,
      }:
      let
        extraModulesPath = "${configFlake}/extra-modules";
      in
      if !(pathExists extraModulesPath) then
        [ ]
      else
        map (filePath: _importExtraModule { inherit filePath narHash; }) (
          flatten (
            icedosLib.scanModules {
              path = extraModulesPath;
              filename = "icedos.nix";
            }
          )
        );

    # Get the configuration flake (either from inputs or local filesystem)
    _getConfigFlake =
      if (hasAttr "icedos-config" inputs) then
        inputs.icedos-config
      else
        builtins.getFlake "path:${ICEDOS_CONFIG_ROOT}";

    # Main function to resolve and process all modules from config
    # Deduplicates modules, extracts outputs, and combines external + extra modules
    modulesFromConfig =
      let
        inherit (builtins)
          attrValues
          listToAttrs
          ;

        inherit (lib) flatten;

        # Resolve external dependencies from config repositories
        externalModules = (
          resolveExternalDependencyRecursively {
            newDeps = config.repositories;
            loadOverrides = true;
          }
        );

        # Deduplicate modules by (url, name) pair
        deduped = attrValues (
          listToAttrs (
            map (m: {
              name = "${m._repoInfo.url}-${m.meta.name}";
              value = m;
            }) (flatten externalModules)
          )
        );

        # Get outputs from external modules
        externalOutputs = getExternalModuleOutputs deduped;

        # Get config flake and load extra modules
        configFlake = _getConfigFlake;
        inherit (configFlake) narHash;
        extraModules = _loadExtraModules { inherit configFlake narHash; };

        # Get outputs from extra modules
        extraOutputs = getExternalModuleOutputs (flatten extraModules);

        # Combine nixos modules from both external and extra sources
        nixosModules = params: (externalOutputs.nixosModules params) ++ (extraOutputs.nixosModules params);

        # Final combined outputs
        outputs = externalOutputs // {
          inherit nixosModules;
          inputs = externalOutputs.inputs ++ extraOutputs.inputs;
          outputs = externalOutputs.outputs ++ extraOutputs.outputs;
          nixosModulesText = externalOutputs.nixosModulesText ++ extraOutputs.nixosModulesText;
        };
      in
      outputs;
  };
in
finalIcedosLib
