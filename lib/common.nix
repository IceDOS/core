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

  _guardExtraFlakeInput =
    flakeName: inputs:
    abortIf (!(inputs ? ${flakeName}))
      "icedos.system.extra-flakes: input '${flakeName}' is not present in the flake inputs (registered as a top-level input via `name`)";
}
