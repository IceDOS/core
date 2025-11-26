{ lib, ... }:

let
  inherit (builtins)
    attrNames
    filter
    foldl'
    head
    length
    listToAttrs
    map
    stringLength
    substring
    ;

  inherit (lib)
    flatten
    hasAttrByPath
    splitString
    unique
    ;

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

  flatMap = cb: list: flatten (map cb list);

  findFirst =
    cb: list:
    let
      found = filter cb list;
    in
    if (length found) > 0 then head found else null;

  generateAttrPath = base: string: foldl' (acc: cur: acc.${cur}) base (splitString "." string);
}
