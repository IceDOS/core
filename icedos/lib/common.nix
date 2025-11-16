{ lib, ... }:

let
  inherit (builtins)
    filter
    attrNames
    foldl'
    listToAttrs
    map
    stringLength
    substring
    ;

  inherit (lib) hasAttrByPath unique;

in
{
  abortIf =
    let
      inherit (builtins) throw;
    in
    condition: message: if condition then throw message else true;

  filterByAttrs = path: listOfAttrSets: filter (attrSet: hasAttrByPath path attrSet) listOfAttrSets;

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
}
