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

    inherit (lib) mkOption types;

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

    filterByAttrs =
      let
        inherit (lib)
          filter
          hasAttrByPath
          ;
      in
      path: atrrset: filter (attr: hasAttrByPath path attr) atrrset;

    stringStartsWith =
      text: original: text == (with builtins; substring 0 (stringLength text) original);

    inputIsOverride =
      { input }:
      let
        inherit (builtins) hasAttr;
      in
      (hasAttr "override" input) && input.override;

    getFullSubmoduleName =
      {
        name,
        subMod ? "0",
      }:
      "${INPUTS_PREFIX}-${name}-${subMod}";

    scanModules =
      {
        path,
        filename,
        maxDepth ? -1,
      }:
      let
        inherit (builtins)
          attrNames
          map
          readDir
          ;

        inherit (lib)
          filterAttrs
          flatten
          optional
          ;

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

    getExternalModule =
      {
        name,
        url,
        ...
      }:
      let
        inherit (builtins)
          fromJSON
          getEnv
          getFlake
          pathExists
          readFile
          ;

        inherit (lib)
          flatten
          hasAttr
          hasAttrByPath
          optionalAttrs
          ;

        flakeRev =
          let
            lock = fromJSON (readFile ./flake.lock);
            node = getFullSubmoduleName { inherit name; };
          in
          if (getEnv "ICEDOS_UPDATE" == "1") then
            ""
          else if (stringStartsWith "path:" url) && (getEnv "ICEDOS_STAGE" == "genflake") then
            ""
          else if (hasAttrByPath [ "nodes" node "locked" "rev" ] lock) then
            "/${lock.nodes.${node}.locked.rev}"
          else if (hasAttrByPath [ "nodes" node "locked" "narHash" ] lock) then
            "?narHash=${lock.nodes.${node}.locked.narHash}"
          else
            "";

        rev = if (pathExists ./flake.lock) then flakeRev else "";

        flakeUrl = "${url}${rev}";
        flake =
          if (getEnv "ICEDOS_STAGE" == "genflake") then
            (getFlake flakeUrl)
          else
            inputs.${getFullSubmoduleName { inherit name; }};

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
        inherit (lib) fileContents pathExists;
      in
      if (pathExists file) then
        ''
          (
            ${fileContents file}
          )
        ''
      else
        "";

    getExternalModuleOutputs =
      mod:
      let
        inherit (builtins)
          attrNames
          elem
          ;

        inherit (lib)
          filter
          flatten
          hasAttr
          listToAttrs
          map
          removeAttrs
          ;

        flake = getExternalModule mod;

        modules =
          filter
            (subModule: (elem subModule.meta.name mod.modules or [ ]) || subModule.meta.name == "default")
            (
              map (
                f:
                import f {
                  inherit config lib;
                  icedosLib = myLib;
                }
              ) flake.files
            );

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
                        name = mod.name;
                        subMod = meta.name;
                      }
                    }-${i}";
                value = removeAttrs inputs.${i} [ "override" ];
              }
            ) (attrNames inputs)
          ) (filterByAttrs [ "inputs" ] modules)
        );

        flakeRev =
          if (hasAttr "rev" flake) then
            "/${flake.rev}"
          else if (hasAttr "narHash" flake) then
            "?narHash=${flake.narHash}"
          else
            "";

        inputs = [
          {
            name = getFullSubmoduleName { name = mod.name; };
            value = {
              url = "${mod.url}${flakeRev}";
            };
          }
        ]
        ++ moduleInputs;

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

              self = inputs.${getFullSubmoduleName { name = mod.name; }};
            }
            // remappedInputs;
          in
          flatten (
            map (mod: mod { inputs = maskedInputs; }) (flatten (map (mod: mod.outputs.nixosModules) modules))
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
          readFile
          toFile
          toJSON
          ;

        inputsJson = toFile "inputs.json" (toJSON inputs);

        inputsNix =
          with pkgs;
          derivation {
            inherit system;
            name = "inputs.nix";
            builder = "${bash}/bin/bash";
            __noChroot = true;
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
