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

  inherit (lib) flatten hasAttrByPath;

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

    getFullSubmoduleName =
      {
        url,
        subMod ? null,
      }:
      replaceStrings [ ":" "/" "." "?" "=" ] [ "_" "_" "_" "_" "_" ] (
        if subMod == null then "${INPUTS_PREFIX}-${url}" else "${INPUTS_PREFIX}-${url}-${subMod}"
      );

    fetchModulesRepository =
      {
        url,
        overrides,
        ...
      }:
      let
        inherit (builtins)
          fromJSON
          getEnv
          getFlake
          ;

        _url = if (hasAttr url overrides) then overrides.${url} else url;

        inherit (lib) optionalAttrs;

        repoName = getFullSubmoduleName { url = _url; };

        flakeRev =
          let
            lock = fromJSON (readFile "${self}/flake.lock");
          in
          if (getEnv "ICEDOS_UPDATE" == "1") then
            ""
          else if (stringStartsWith "path:" _url) && (ICEDOS_STAGE == "genflake") then
            ""
          else if (hasAttrByPath [ "nodes" repoName "locked" "rev" ] lock) then
            "/${lock.nodes.${repoName}.locked.rev}"
          else if (hasAttrByPath [ "nodes" repoName "locked" "narHash" ] lock) then
            "?narHash=${lock.nodes.${repoName}.locked.narHash}"
          else
            "";

        rev = if (pathExists "${self}/flake.lock") then flakeRev else "";

        flakeUrl = "${_url}${rev}";
        flake = if (ICEDOS_STAGE == "genflake") then (getFlake flakeUrl) else inputs.${repoName};

        modules = flake.icedosModules { icedosLib = finalIcedosLib; };
      in
      {
        url = _url;
        inherit (flake) narHash;
        files = flatten modules;
      }
      // (optionalAttrs (hasAttr "rev" flake) { inherit (flake) rev; });

    getExternalModuleOutputs =
      modules:
      let
        inherit (builtins) attrNames filter;
        inherit (lib) flatten hasAttr listToAttrs;

        modulesAsInputs =
          map
            (
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
            )
            (
              filter (
                mod: !(hasAttr "skipModuleAsInput" mod._repoInfo && mod._repoInfo.skipModuleAsInput)
              ) modules
            );

        moduleInputs = flatten (
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
                isOverride = inputIsOverride {
                  input = inputs.${i};
                };
              in
              {
                _originalName = i;
                name =
                  if isOverride then
                    i
                  else
                    "${
                      if (hasAttr "skipModuleAsInput" _repoInfo && _repoInfo.skipModuleAsInput) then
                        "icedos-config"
                      else
                        getFullSubmoduleName {
                          inherit (_repoInfo) url;
                          subMod = meta.name;
                        }
                    }-${i}";
                value = removeAttrs inputs.${i} [ "override" ];
              }
            ) (attrNames inputs)
          ) (filterByAttrs [ "inputs" ] modules)
        );

        inputs = modulesAsInputs ++ moduleInputs;

        options = map (
          { options, ... }:
          {
            inherit options;
          }
        ) (filterByAttrs [ "options" ] modules);

        nixosModulesPerIcedosModule =
          { inputs, ... }:
          { _repoInfo, outputs, ... }:
          let
            remappedInputs = listToAttrs (
              map (i: {
                name = i._originalName;
                value = inputs.${i.name};
              }) moduleInputs
            );

            maskedInputs = {
              inherit (inputs) nixpkgs home-manager;
              icedos-state = if (hasAttr "icedos-state" inputs) then inputs.icedos-state else null;
              self =
                if (hasAttr "skipModuleAsInput" _repoInfo && _repoInfo.skipModuleAsInput) then
                  "icedos-config"
                else
                  inputs.${getFullSubmoduleName { inherit (_repoInfo) url; }};
            }
            // remappedInputs;
          in
          outputs.nixosModules { inputs = maskedInputs; };

        nixosModules =
          params:
          flatten (
            map (nixosModulesPerIcedosModule params) (filterByAttrs [ "outputs" "nixosModules" ] modules)
          );

        nixosModulesText = (
          flatten (
            map (mod: mod.outputs.nixosModulesText) (filterByAttrs [ "outputs" "nixosModulesText" ] modules)
          )
        );
      in
      {
        inherit
          inputs
          nixosModules
          nixosModulesText
          options
          ;
      };

    resolveExternalDependencyRecursively =
      {
        newDeps,
        existingDeps ? [ ],
        existingOverrides ? [ ],
        loadOverrides ? false,
      }:
      let
        inherit (builtins)
          elem
          filter
          foldl'
          length
          listToAttrs
          ;

        inherit (lib) optional optionals unique;

        getModuleKey = url: name: "${url}/${name}";

        overrides =
          let
            filteredDeps = filter (hasAttr "overrideUrl") newDeps;

            result = listToAttrs (
              map (dep: {
                name = dep.url;
                value = dep.overrideUrl;
              }) filteredDeps
            );
          in
          if loadOverrides then result else existingOverrides;

        loadModulesFromRepo =
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

            result =
              if hasDefault then
                modules
              else
                (
                  modules
                  ++ [
                    {
                      _repoInfo = repo;
                      meta.name = "default";
                    }
                  ]
                );
          in
          result;

        result = foldl' (
          acc: newDep:
          let
            # Get list of needed modules
            missingModules = (
              filter (mod: !elem (getModuleKey newDep.url mod) existingDeps) (newDep.modules or [ ])
            );

            # Optional new repo
            newRepo = optional (
              (length missingModules) > 0 || !elem (getModuleKey newDep.url "default") existingDeps
            ) (fetchModulesRepository (newDep // { inherit overrides; }));

            # Convert to list of modules
            newModules = filter (
              mod:
              (!elem (getModuleKey mod._repoInfo.url mod.meta.name) existingDeps)
              && (elem mod.meta.name (newDep.modules or [ ]) || mod.meta.name == "default")
            ) (flatMap loadModulesFromRepo newRepo);

            # Convert to keys
            newModulesKeys = map (mod: getModuleKey mod._repoInfo.url mod.meta.name) newModules;
            allKnownKeys = (unique (existingDeps ++ newModulesKeys));

            # Get deps
            innerDeps = flatMap (
              mod:
              map
                (
                  {
                    url ? newDep.url,
                    modules ? [ ],
                  }:
                  {
                    url = if (url == "self") then newDep.url else url;
                    modules = filter (mod: !elem (getModuleKey url mod) allKnownKeys) modules;
                  }
                )
                (
                  let
                    inherit (mod) meta;
                  in
                  (meta.dependencies or [ ])
                  ++ optionals (newDep.fetchOptionalDependencies or false) (meta.optionalDependencies or [ ])
                )
            ) newModules;
          in
          flatten (
            acc
            ++ newModules
            ++ optional ((length innerDeps) > 0) (resolveExternalDependencyRecursively {
              newDeps = innerDeps;
              existingDeps = allKnownKeys;
              existingOverrides = overrides;
            })
          )
        ) [ ] newDeps;
      in
      result;

    modulesFromConfig =
      let
        inherit (builtins)
          attrValues
          listToAttrs
          ;

        inherit (lib)
          flatten
          ;

        modules = (
          resolveExternalDependencyRecursively {
            newDeps = config.repositories;
            loadOverrides = true;
          }
        );

        deduped = attrValues (
          listToAttrs (
            map (m: {
              name = "${m._repoInfo.url}-${m.meta.name}";
              value = m;
            }) (flatten modules)
          )
        );

        outputsFromDeps = getExternalModuleOutputs deduped;

        outputsFromExtraModules =
          let
            configFlake =
              if (hasAttr "icedos-config" inputs) then
                inputs.icedos-config
              else
                builtins.getFlake "path:${ICEDOS_CONFIG_ROOT}";
            inherit (configFlake) narHash;

            importExtraModule =
              extra:
              (import extra { icedosLib = finalIcedosLib; })
              // {
                _repoInfo = {
                  inherit narHash;
                  url = "path:${extra}";
                  skipModuleAsInput = true;
                };
                meta.name = extra;
              };

            extraModules =
              if (pathExists "${configFlake}/extra-modules") then
                map importExtraModule (
                  flatten (
                    icedosLib.scanModules {
                      path = "${configFlake}/extra-modules";
                      filename = "icedos.nix";
                    }
                  )
                )
              else
                [ ];
          in
          getExternalModuleOutputs (flatten extraModules);

        nixosModules =
          params: (outputsFromDeps.nixosModules params) ++ (outputsFromExtraModules.nixosModules params);

        outputs = outputsFromDeps // {
          inherit nixosModules;
          inputs = outputsFromDeps.inputs ++ outputsFromExtraModules.inputs;
          outputs = outputsFromDeps.outputs ++ outputsFromExtraModules.outputs;
          nixosModulesText = outputsFromDeps.nixosModulesText ++ outputsFromExtraModules.nixosModulesText;
        };
      in
      outputs;
  };
in
finalIcedosLib
