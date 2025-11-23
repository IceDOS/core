{ ... }@icedosLibInputs:

let
  inherit (builtins)
    attrNames
    elem
    filter
    foldl'
    head
    length
    throw
    ;

  findDuplicate = list1: list2: filter (item: elem item list2) list1;

  loadLibs =
    paths:
    foldl' (
      icedosLib: curPath:
      let
        curLib = import curPath (icedosLibInputs // { inherit icedosLib; });

        accFunctionNames = attrNames icedosLib;

        # Load the path without injecting the rest of icedosLib, as we only need the exported function names
        curFunctionNames = attrNames (import curPath (icedosLibInputs // { icedosLib = { }; }));

        mergedLib = icedosLib // curLib;
        mergedNames = attrNames mergedLib;

        result =
          if (length accFunctionNames) + (length curFunctionNames) == (length mergedNames) then
            mergedLib
          else
            throw "Duplicate function '${head (findDuplicate accFunctionNames curFunctionNames)}'";
      in
      result
    ) { } paths;
in
loadLibs [
  # Ordered based on dependencies
  ./constants.nix
  ./common.nix
  ./logger.nix
  ./options.nix
  ./helpers.nix
  ./icedos.nix
]
