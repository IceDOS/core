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
    readFile
    pathExists
    ;

  inherit (lib) flatten hasAttrByPath;

  inherit (icedosLib)
    filterByAttrs
    findFirst
    flatMap
    stringStartsWith
    ICEDOS_STAGE
    INPUTS_PREFIX
    ;

  finalIcedosLib = icedosLib // rec {
    inputIsOverride = { input }: (hasAttr "override" input) && input.override;

    getFullSubmoduleName =
      {
        url,
        subMod ? null,
      }:
      if subMod == null then "${INPUTS_PREFIX}-${url}" else "${INPUTS_PREFIX}-${url}-${subMod}";

    fetchModulesRepository =
      {
        url,
        ...
      }:
      let
        inherit (builtins)
          fromJSON
          getEnv
          getFlake
          ;

        inherit (lib) optionalAttrs;

        repoName = getFullSubmoduleName { inherit url; };

        flakeRev =
          let
            lock = fromJSON (readFile "${self}/flake.lock");
          in
          if (getEnv "ICEDOS_UPDATE" == "1") then
            ""
          else if (stringStartsWith "path:" url) && (ICEDOS_STAGE == "genflake") then
            ""
          else if (hasAttrByPath [ "nodes" repoName "locked" "rev" ] lock) then
            "/${lock.nodes.${repoName}.locked.rev}"
          else if (hasAttrByPath [ "nodes" repoName "locked" "narHash" ] lock) then
            "?narHash=${lock.nodes.${repoName}.locked.narHash}"
          else
            "";

        rev = if (pathExists "${self}/flake.lock") then flakeRev else "";

        flakeUrl = "${url}${rev}";
        flake = if (ICEDOS_STAGE == "genflake") then (getFlake flakeUrl) else inputs.${repoName};

        modules = flake.icedosModules { icedosLib = finalIcedosLib; };
      in
      {
        inherit url;
        inherit (flake) narHash;
        files = flatten modules;
      }
      // (optionalAttrs (hasAttr "rev" flake) { inherit (flake) rev; });

    getExternalModuleOutputs =
      modules:
      let
        inherit (builtins) attrNames;

        inherit (lib)
          flatten
          hasAttr
          listToAttrs
          map
          removeAttrs
          ;

        modulesAsInputs = map (
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
        ) modules;

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

              self = inputs.${getFullSubmoduleName { inherit (_repoInfo) url; }};
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
      }:
      let
        inherit (builtins)
          elem
          filter
          foldl'
          length
          ;

        inherit (lib) optional unique;

        getModuleKey = url: name: "${url}/${name}";

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
            ) (fetchModulesRepository newDep);

            # Convert to list of modules
            newModules = filter (
              mod:
              (!elem (getModuleKey mod._repoInfo.url mod.meta.name) existingDeps)
              && (elem mod.meta.name (newDep.modules or []) || mod.meta.name == "default")
            ) (flatMap loadModulesFromRepo newRepo);

            # Convert to keys
            newModulesKeys = map (mod: getModuleKey mod._repoInfo.url mod.meta.name) newModules;
            allKnownKeys = (unique (existingDeps ++ newModulesKeys));

            # Get deps
            innerDeps = flatMap (
              mod:
              map (
                {
                  url ? newDep.url,
                  modules ? [],
                }:
                {
                  url = if (url == "self") then newDep.url else url;
                  modules = filter (mod: !elem (getModuleKey url mod) allKnownKeys) modules;
                }
              ) (mod.meta.dependencies or [ ])
            ) newModules;
          in
          flatten (
            acc
            ++ newModules
            ++ optional ((length innerDeps) > 0) (resolveExternalDependencyRecursively {
              newDeps = innerDeps;
              existingDeps = allKnownKeys;
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

        modules = (resolveExternalDependencyRecursively { newDeps = config.repositories; });

        deduped = attrValues (
          listToAttrs (
            map (m: {
              name = "${m._repoInfo.url}-${m.meta.name}";
              value = m;
            }) (flatten modules)
          )
        );

        outputs = getExternalModuleOutputs deduped;
      in
      outputs;
  };
in
finalIcedosLib
