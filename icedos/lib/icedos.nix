{
  config,
  icedosLib,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (builtins)
    hasAttr
    readFile
    pathExists
    ;

  inherit (lib) filterAttrs flatten;

  inherit (icedosLib)
    filterByAttrs
    hasAttrByPath
    stringStartsWith
    ICEDOS_STAGE
    INPUTS_PREFIX
    ;

  finalIcedosLib = icedosLib // (rec {
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
            lock = fromJSON (readFile ./flake.lock);
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

        rev = if (pathExists ./flake.lock) then flakeRev else "";

        flakeUrl = "${url}${rev}";
        flake = if (ICEDOS_STAGE == "genflake") then (getFlake flakeUrl) else inputs.${repoName};

        modules = flake.icedosModules { icedosLib = finalIcedosLib; };
      in
      {
        inherit (flake) narHash;
        files = flatten modules;
      }
      // (optionalAttrs (hasAttr "rev" flake) { inherit (flake) rev; });

    resolveExternalDependencyRecursively =
      repoCfg:
      let
        inherit (builtins)
          attrValues
          elem
          filter
          foldl'
          map
          ;

        inherit (lib) flatten;

        repo = fetchModulesRepository repoCfg;

        modules =
          let
            isDefault = name: if hasAttr "noDefault" repoCfg then false else (name == "default");
          in
          filter
            (
              subModule:
              let
                subModuleName = subModule.meta.name;
              in
              (elem subModuleName repoCfg.modules or [ ]) || isDefault subModuleName
            )
            (
              map (
                f:
                import f {
                  inherit config lib;
                  icedosLib = finalIcedosLib;
                }
              ) repo.files
            );

        dependencies =
          let
            deps = flatten (map (m: m.meta.dependencies) (filterByAttrs [ "meta" "dependencies" ] modules));
          in
          map (
            {
              url ? "self",
              modules ? [ ],
            }:
            if url == "self" then
              resolveExternalDependencyRecursively {
                inherit (repoCfg) url;
                inherit modules;
                noDefault = true;
              }
            else
              resolveExternalDependencyRecursively {
                inherit url modules;
              }
          ) deps;

        allDeps = flatten ([ (repoCfg // { inherit modules repo; }) ] ++ dependencies);
        deduped = attrValues (foldl' (acc: dep: acc // { ${dep.url} = dep; }) { } allDeps);
      in
      deduped;

    extractIcedosModules =
      repos:
      let
        inherit (builtins) map;

        inherit (lib) flatten;

        modulesPerRepo = map (r: map (m: m // { _repoInfo = r; }) r.modules) repos;
      in
      flatten (modulesPerRepo);

    getExternalModuleOutputs =
      modules:
      let
        inherit (builtins)
          attrNames
          foldl'
          ;

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
            inherit (_repoInfo) repo url;

            flakeRev =
              if (hasAttr "rev" repo) then
                "/${repo.rev}"
              else if (hasAttr "narHash" repo) then
                "?narHash=${repo.narHash}"
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
          { options, meta, ... }:
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

    serializeAllExternalInputs =
      inputs:
      let
        inherit (builtins)
          toFile
          toJSON
          ;

        inputsJson = toFile "inputs.json" (toJSON inputs);

        inputsNix =
          with pkgs;
          derivation {
            inherit (pkgs.stdenv.hostPlatform) system;
            __noChroot = true;
            builder = "${bash}/bin/bash";
            name = "inputs.nix";

            args = [
              "-c"
              ''
                export PATH=${coreutils}/bin:${gnused}/bin:${nix}/bin:${nixfmt-rfc-style}/bin
                nix-instantiate --eval -E 'with builtins; fromJSON (readFile ${inputsJson})' | nixfmt | sed '1,1d' | sed '$d' >$out
              ''
            ];
          };
      in
      readFile inputsNix;

    modulesFromConfig =
      let
        inherit (builtins)
          attrValues
          listToAttrs
          ;

        inherit (lib)
          flatten
          ;

        modules = map (
          repo: extractIcedosModules (resolveExternalDependencyRecursively repo)
        ) config.repositories;

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
  });
in
finalIcedosLib
