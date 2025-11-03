{
  self,
  config,
  lib,
  pkgs,
  inputs ? { },
  ...
}:

let
  myLib = rec {
    INPUTS_PREFIX = "icedos";

    inherit (lib)
      attrNames
      filter
      filterAttrs
      flatten
      foldl'
      hasAttr
      hasAttrByPath
      lists
      mkOption
      pathExists
      readFile
      splitString
      types
      ;

    mkBoolOption = args: mkOption (args // { type = types.bool; });
    mkLinesOption = args: mkOption (args // { type = types.lines; });
    mkNumberOption = args: mkOption (args // { type = types.number; });
    mkStrListOption = args: mkOption (args // { type = with types; listOf str; });
    mkStrOption = args: mkOption (args // { type = types.str; });

    mkFunctionOption =
      args:
      mkOption (
        args
        // {
          type = types.function;
        }
      );

    mkSubmoduleAttrsOption =
      args: options:
      mkOption (
        args
        // {
          type = types.attrsOf (
            types.submodule {
              options = options;
            }
          );
        }
      );

    mkSubmoduleListOption =
      args: options:
      mkOption (
        args
        // {
          type = types.listOf (
            types.submodule {
              options = options;
            }
          );
        }
      );

    abortIf =
      let
        inherit (builtins) throw;
      in
      condition: message: if condition then throw message else true;

    generateAccentColor =
      {
        accentColor,
        gnomeAccentColor,
        hasGnome,
      }:
      if (!hasGnome) then
        "#${accentColor}"
      else
        {
          blue = "#3584e4";
          green = "#3a944a";
          orange = "#ed5b00";
          pink = "#d56199";
          purple = "#9141ac";
          red = "#e62d42";
          slate = "#6f8396";
          teal = "#2190a4";
          yellow = "#c88800";
        }
        .${gnomeAccentColor};

    getNormalUsers =
      { users }:
      let
        inherit (lib) mapAttrsToList;
      in
      mapAttrsToList (name: attrs: {
        inherit name;
        value = attrs;
      }) (filterAttrs (n: v: v.isNormalUser) users);

    pkgMapper =
      pkgList: lists.map (pkgName: foldl' (acc: cur: acc.${cur}) pkgs (splitString "." pkgName)) pkgList;

    filterByAttrs = path: listOfAttrSets: filter (attrSet: hasAttrByPath path attrSet) listOfAttrSets;

    stringStartsWith =
      text: original: text == (with builtins; substring 0 (stringLength text) original);

    inputIsOverride = { input }: (hasAttr "override" input) && input.override;

    getFullSubmoduleName =
      {
        url,
        subMod ? null,
      }:
      if subMod == null then "${INPUTS_PREFIX}-${url}" else "${INPUTS_PREFIX}-${url}-${subMod}";

    scanModules =
      {
        path,
        filename,
        maxDepth ? -1,
      }:
      let
        inherit (builtins) readDir;
        inherit (lib) optional;

        getContentsByType = fileType: filterAttrs (name: type: type == fileType) contents;

        targetPath = if (stringStartsWith "/nix/store" "${path}") then "${path}" else "${self}/${path}";
        contents = readDir targetPath;

        directories = getContentsByType "directory";
        files = getContentsByType "regular";

        directoriesPaths = map (n: "${path}/${n}") (attrNames directories);

        icedosFiles = filterAttrs (n: v: n == filename) files;
        icedosFilesPaths = map (n: "${targetPath}/${n}") (attrNames icedosFiles);
      in
      icedosFilesPaths
      ++ optional (maxDepth != 0) (
        flatten (
          map (
            dp:
            scanModules {
              inherit filename;
              path = dp;
              maxDepth = maxDepth - 1;
            }
          ) directoriesPaths
        )
      );

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
          else if (stringStartsWith "path:" url) && (getEnv "ICEDOS_STAGE" == "genflake") then
            ""
          else if (hasAttrByPath [ "nodes" repoName "locked" "rev" ] lock) then
            "/${lock.nodes.${repoName}.locked.rev}"
          else if (hasAttrByPath [ "nodes" repoName "locked" "narHash" ] lock) then
            "?narHash=${lock.nodes.${repoName}.locked.narHash}"
          else
            "";

        rev = if (pathExists ./flake.lock) then flakeRev else "";

        flakeUrl = "${url}${rev}";
        flake = if (getEnv "ICEDOS_STAGE" == "genflake") then (getFlake flakeUrl) else inputs.${repoName};

        modules = flake.icedosModules { icedosLib = myLib; };
      in
      {
        inherit (flake) narHash;
        files = flatten modules;
      }
      // (optionalAttrs (hasAttr "rev" flake) { inherit (flake) rev; });

    injectIfExists =
      { file }:
      let
        inherit (lib) fileContents;
      in
      if (pathExists file) then
        ''
          (
            ${fileContents file}
          )
        ''
      else
        "";

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
          filter
            (subModule: (elem subModule.meta.name repoCfg.modules or [ ]) || subModule.meta.name == "default")
            (
              map (
                f:
                import f {
                  inherit config lib;
                  icedosLib = myLib;
                }
              ) repo.files
            );

        dependencies =
          let
            dependencies = flatten (
              map (m: m.meta.dependencies) (filterByAttrs [ "meta" "dependencies" ] modules)
            );
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
              }
            else
              resolveExternalDependencyRecursively {
                inherit url modules;
              }
          ) dependencies;

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
      cfgRepo:
      let
        inherit (builtins)
          attrNames
          ;

        inherit (lib)
          flatten
          hasAttr
          listToAttrs
          map
          removeAttrs
          ;

        modules = extractIcedosModules (resolveExternalDependencyRecursively cfgRepo);

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
            { inputs, meta, ... }:
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
                        inherit (cfgRepo) url;
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

        nixosModules =
          { inputs, ... }:
          let
            remappedInputs = listToAttrs (
              map (i: {
                name = i._originalName;
                value = inputs.${i.name};
              }) moduleInputs
            );

            maskedInputs = {
              inherit (inputs) nixpkgs home-manager;

              self = inputs.${getFullSubmoduleName { inherit (cfgRepo) url; }};
            }
            // remappedInputs;
          in
          flatten (
            map (mod: mod { inputs = maskedInputs; }) (
              flatten (map (mod: if (hasAttr "outputs" mod) then mod.outputs.nixosModules else [ ]) modules)
            )
          );

        nixosModulesText = flatten (
          map (mod: mod.outputs.nixosModulesText) (filterByAttrs [ "outputs" "nixosModulesText" ] modules)
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
  };
in
myLib
