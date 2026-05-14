configRoot:
let
  inherit (builtins)
    attrNames
    concatStringsSep
    filter
    isAttrs
    isList
    listToAttrs
    mapAttrs
    pathExists
    readFile
    ;

  filterAttrs =
    pred: set:
    listToAttrs (
      map (n: {
        name = n;
        value = set.${n};
      }) (filter (n: pred n set.${n}) (attrNames set))
    );

  mainPath = "${configRoot}/config.toml";
  privPath = "${configRoot}/.private.toml";

  main = fromTOML (readFile mainPath);
  priv = if pathExists privPath then fromTOML (readFile privPath) else { };

  mergeStrict =
    path: a: b:
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
          mergeStrict subPath av bv
        else if isList av && isList bv then
          av ++ bv
        else
          throw "duplicate config key '${concatStringsSep "." subPath}' present in both config.toml AND .private.toml — choose one"
      ) both;
    in
    onlyA // onlyB // resolved;
in
mergeStrict [ ] main priv
