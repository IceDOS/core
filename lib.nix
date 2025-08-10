{
  self,
  config,
  lib,
  pkgs,
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

    filterByAttrs =
      let
        inherit (lib)
          filter
          hasAttrByPath
          ;
      in
      path: atrrset: filter (attr: hasAttrByPath path attr) atrrset;

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
          substring
          ;

        inherit (lib)
          filterAttrs
          flatten
          optional
          ;

        getContentsByType = fileType: filterAttrs (name: type: type == fileType) contents;

        targetPath = if ((substring 0 10 "${path}") == "/nix/store") then "${path}" else "${self}/${path}";
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
          getFlake
          pathExists
          readFile
          ;

        inherit (lib)
          flatten
          hasAttrByPath
          ;

        flakeRev =
          let
            lock = fromJSON (readFile ./flake.lock);
            node = getFullSubmoduleName { inherit name; };
          in
          if (hasAttrByPath [ "nodes" node "locked" "rev" ] lock) then
            "/${lock.nodes.${node}.locked.rev}"
          else if (hasAttrByPath [ "nodes" node "locked" "narHash" ] lock) then
            "?narHash=${lock.nodes.${node}.locked.narHash}"
          else
            "";

        rev = if (pathExists ./flake.lock) then flakeRev else "";

        flake = getFlake "${url}${rev}";

        modules = flake.icedosModules { icedosLib = myLib; };
      in
      flatten modules;

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
          listToAttrs
          map
          ;

        files = getExternalModule mod;

        modules = filter (subModule: elem subModule.meta.name mod.modules) (
          map (
            f:
            import f {
              inherit config lib;
              icedosLib = myLib;
            }
          ) files
        );

        moduleInputs = flatten (
          map (
            { inputs, meta, ... }:
            map (i: {
              _originalName = i;
              name = "${
                getFullSubmoduleName {
                  name = mod.name;
                  subMod = meta.name;
                }
              }-${i}";
              value = inputs.${i};
            }) (attrNames inputs)
          ) (filterByAttrs [ "inputs" ] modules)
        );

        inputs = [
          {
            name = getFullSubmoduleName { name = mod.name; };
            value = { inherit (mod) url; };
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
              inherit (inputs) nixpkgs;
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
      mods:
      let
        inherit (builtins)
          readFile
          toFile
          toJSON
          ;

        inherit (lib)
          flatten
          listToAttrs
          map
          ;

        allInputs = flatten (map (mod: mod.inputs) mods);
        inputsJson = toFile "inputs.json" (toJSON (listToAttrs allInputs));

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
