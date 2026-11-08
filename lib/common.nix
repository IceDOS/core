{ lib, ... }:

let
  inherit (builtins)
    attrNames
    filter
    foldl'
    head
    length
    listToAttrs
    stringLength
    substring
    ;

  inherit (lib)
    flatten
    hasAttrByPath
    splitString
    unique
    ;

  abortIf = condition: message: if condition then throw message else true;
in
{
  inherit abortIf;
  filterByAttrs = path: listOfAttrSets: filter (attrSet: hasAttrByPath path attrSet) listOfAttrSets;

  findFirst =
    cb: list:
    let
      found = filter cb list;
    in
    if (length found) > 0 then head found else null;

  flatMap = cb: list: flatten (map cb list);

  listToAttrsetOfLists =
    attrsList:
    let
      allKeys = foldl' (acc: x: acc ++ (attrNames x)) [ ] attrsList;
      uniqueKeys = unique allKeys;
      collectValues = key: map (attrset: attrset.${key}) attrsList;
    in
    listToAttrs (
      map (key: {
        name = key;
        value = collectValues key;
      }) uniqueKeys
    );

  stringStartsWith = text: original: text == (substring 0 (stringLength text) original);
  generateAttrPath = base: string: foldl' (acc: cur: acc.${cur}) base (splitString "." string);

  # Resolve a dotted path against a flake's outputs, naming the missing input/segment.
  # Empty path returns the flake root after asserting input presence.
  _selectExtraFlakeOutput =
    flakeName: path: inputs:
    let
      inherit (builtins) seq;
      input = seq (abortIf (!(inputs ? ${flakeName}))
        "icedos.system.extra-flakes: input '${flakeName}' is not present in the flake inputs (registered as a top-level input via `name`)"
      ) inputs.${flakeName};
    in
    if path == "" then
      input
    else
      let
        segments = splitString "." path;
        walk =
          node: seg:
          seq (abortIf (!(node ? ${seg}))
            "icedos.system.extra-flakes: output path '${path}' on flake input '${flakeName}' is missing segment '${seg}'"
          ) node.${seg};
        selected = foldl' walk input segments;
        nullGuard = abortIf (
          selected == null
        ) "icedos.system.extra-flakes: output '${path}' on flake input '${flakeName}' is missing or null";
      in
      seq nullGuard selected;
}
