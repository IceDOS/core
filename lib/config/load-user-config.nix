configRoot:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    filter
    foldl'
    isAttrs
    isList
    listToAttrs
    mapAttrs
    ;

  filterAttrs =
    pred: set:
    listToAttrs (
      map (n: {
        name = n;
        value = set.${n};
      }) (filter (n: pred n set.${n}) (attrNames set))
    );

  # Shared with modules/options.nix, so the two can never disagree about which
  # files are loaded.
  configFiles = import ./config-files.nix configRoot;

  # Attrs recurse, lists concatenate, the same scalar key in two files is a hard
  # error naming both.
  mergeStrict =
    bRel: path: a: b:
    let
      onlyA = filterAttrs (k: _: !(b ? ${k})) a;
      onlyB = filterAttrs (k: _: !(a ? ${k})) b;
      both = filterAttrs (k: _: a ? ${k}) b;
      resolved = mapAttrs (
        k: bv:
        let
          av = a.${k};
          subPath = path ++ [ k ];
        in
        if isAttrs av && isAttrs bv then
          mergeStrict bRel subPath av bv
        else if isList av && isList bv then
          av ++ bv
        else
          throw "duplicate config key '${concatStringsSep "." subPath}' — set in '${bRel}' and an earlier config file; define it in exactly one"
      ) both;
    in
    onlyA // onlyB // resolved;
in
foldl' (acc: f: mergeStrict f.rel [ ] acc f.content) { } configFiles
