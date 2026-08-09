# Translate the user-written `[extraOptions]` TOML table into a NixOS module
# that declares those options — letting a user define their own typed options
# purely from config.toml / configs/*.toml, with no Nix module to write.
#
# The `[extraOptions]` table is a recursive tree:
#   * a node with a `type` key is a TYPED LEAF — one declared option. Every
#     other key must be a known meta key (`default`, `description`, and the
#     type's own constraints).
#   * a node without `type` is a NAMESPACE — a pure grouping segment; every key
#     is a child path segment (another table), never a scalar value.
# Option paths are full dotted paths from the config root, so
# `[extraOptions.icedos.applications.myapp]` with a leaf `enable` declares
# `options.icedos.applications.myapp.enable`, and `[extraOptions.services.myapp]`
# declares `options.services.myapp`. Non-icedos paths are allowed and merge with
# nixpkgs / IceDOS options.
#
# Values reach the running system by the same routes as ordinary config:
#   * `icedos.*` options through the per-file `config.icedos` imports in
#     modules/options.nix;
#   * non-icedos options through the raw NixOS passthrough in genflake.nix.
# At the genflake stage that passthrough is absent, so `inject` re-applies the
# declared non-icedos values per-path — that is what makes the search index show
# real values instead of null for custom options.
#
# The generated module is wrapped in `lib.setDefaultModuleLocation` with
# `marker`, which lands the marker string in every declared option's
# `declarations` — genflake's optionsDoc keep-filter matches on it to include
# non-icedos custom options in the index.
#
# loadLibs constraint: `lib/default.nix` probes each lib file with a bare
# icedosLib and enumerates only the top-level exported names, so this file
# exports a single top-level attrset (`extraOptions`) and references icedosLib
# members only inside the exported functions.
{
  icedosLib,
  lib,
  ...
}:

let
  inherit (builtins)
    all
    attrNames
    concatMap
    concatStringsSep
    elem
    elemAt
    filter
    foldl'
    genList
    head
    isAttrs
    isFloat
    isInt
    isList
    isString
    length
    mapAttrs
    tail
    ;

  inherit (lib)
    getAttrFromPath
    mkOption
    setAttrByPath
    setDefaultModuleLocation
    showOption
    types
    ;

  inherit (icedosLib) abortIf validate;

  # Shared provenance marker. Landed in the `_file` of every generated module so
  # (a) `o.declarations` carries it for the optionsDoc keep-filter, and (b) type
  # / merge errors point at "config.toml / configs/*.toml" instead of an
  # anonymous generated location. Also the `source` attribute for validate.*.
  marker = "extraOptions (config.toml / configs/*.toml)";
  source = marker;

  # Error-path rendering: the dotted path of the custom option being described
  # (e.g. "services.myapp.port"), or a bare marker for the root table.
  fmtPath = path: if path == [ ] then "extraOptions" else showOption path;

  # A TOML value in error text.
  fmtVal =
    v:
    if isAttrs v then
      "<table>"
    else if isList v then
      "<list>"
    else
      toString v;

  isNum = v: isInt v || isFloat v;

  # Bare-name item types: the scalar types a `list`/`attrs` `item` may name
  # directly. Composite / constraint-carrying items are written as a descriptor
  # table instead (see `validateItem`).
  scalarTypes = [
    "bool"
    "string"
    "number"
    "int"
    "float"
    "nonEmptyString"
    "lines"
  ];

  knownTypes = scalarTypes ++ [
    "enum"
    "stringList"
    "numberList"
    "intList"
    "floatList"
    "list"
    "attrs"
    "record"
  ];

  # Meta keys allowed on a typed leaf, per type. `type` itself is checked
  # separately, so it is not listed here.
  leafMetaKeys =
    t:
    if
      elem t [
        "bool"
        "nonEmptyString"
        "lines"
        "stringList"
        "numberList"
        "intList"
        "floatList"
      ]
    then
      [
        "default"
        "description"
      ]
    else if t == "string" then
      [
        "default"
        "description"
        "minLength"
        "maxLength"
        "regex"
      ]
    else if
      elem t [
        "number"
        "int"
        "float"
      ]
    then
      [
        "default"
        "description"
        "min"
        "max"
      ]
    else if t == "enum" then
      [
        "default"
        "description"
        "choices"
      ]
    else if
      elem t [
        "list"
        "attrs"
      ]
    then
      [
        "default"
        "description"
        "item"
      ]
    else if t == "record" then
      [
        "default"
        "description"
        "fields"
      ]
    else
      [ ];

  # --- schema validation (aborts with rich path messages) -------------------

  validateNode =
    path: node: if node ? type then validateLeaf path node else validateNamespace path node;

  validateNamespace =
    path: node:
    abortIf (!(isAttrs node)) "${fmtPath path}: extraOptions must be a table of option declarations"
    && foldl' (
      acc: k:
      let
        child = node.${k};
      in
      acc
      && (
        if isAttrs child then
          validateNode (path ++ [ k ]) child
        else
          throw "${fmtPath path}: '${k}' has no 'type' but is a scalar value — namespace segments must be tables; add a 'type' to declare an option"
      )
    ) true (attrNames node);

  # Every field of a typed leaf must be a known meta key. `validateLeaf` returns
  # `true` or throws; `validateItem` / `validateFields` recurse into the
  # descriptor subtrees (`item`, `fields`) that shape a type rather than the
  # option tree.
  validateLeaf =
    path: node:
    let
      t = node.type;
      allowed = leafMetaKeys t;
      allKeys = attrNames node;

      unexpected = filter (k: !(elem k (allowed ++ [ "type" ]))) allKeys;

      numConstraintsOk =
        if
          elem t [
            "number"
            "int"
            "float"
          ]
        then
          abortIf (node ? min && !(isNum node.min)) "${fmtPath path}: 'min' must be a number"
          && abortIf (node ? max && !(isNum node.max)) "${fmtPath path}: 'max' must be a number"
          && abortIf (
            t == "int" && node ? min && !(isInt node.min)
          ) "${fmtPath path}: 'min' must be an integer for type 'int'"
          && abortIf (
            t == "int" && node ? max && !(isInt node.max)
          ) "${fmtPath path}: 'max' must be an integer for type 'int'"
        else
          true;

      strConstraintsOk =
        if t == "string" then
          abortIf (
            node ? minLength && !(isInt node.minLength)
          ) "${fmtPath path}: 'minLength' must be an integer"
          && abortIf (
            node ? maxLength && !(isInt node.maxLength)
          ) "${fmtPath path}: 'maxLength' must be an integer"
          &&
            abortIf (node ? minLength && node ? maxLength && node.minLength > node.maxLength)
              "${fmtPath path}: 'minLength' (${toString node.minLength}) exceeds 'maxLength' (${toString node.maxLength})"
          && abortIf (node ? regex && !(isString node.regex)) "${fmtPath path}: 'regex' must be a string"
        else
          true;

      enumOk =
        if t == "enum" then
          let
            choices = node.choices or null;
          in
          abortIf (
            !(isList choices) || length choices == 0
          ) "${fmtPath path}: type 'enum' requires a non-empty 'choices' list"
          && abortIf (
            node ? default && !(elem node.default choices)
          ) "${fmtPath path}: 'default' '${fmtVal node.default}' must be one of the 'choices'"
        else
          true;

      itemOk =
        if
          elem t [
            "list"
            "attrs"
          ]
        then
          abortIf (!(node ? item)) "${fmtPath path}: type '${t}' requires an 'item' descriptor"
          && validateItem path node
        else
          true;

      recordOk =
        if t == "record" then
          abortIf (
            !(node ? fields) || !(isAttrs node.fields)
          ) "${fmtPath path}: type 'record' requires a 'fields' table"
          && validateFields path node
        else
          true;
    in
    abortIf (!(isString node.type)) "${fmtPath path}: 'type' must be a type name string"
    && abortIf (!(elem t knownTypes)) "${fmtPath path}: unknown type '${t}'"
    && abortIf (
      unexpected != [ ]
    ) "${fmtPath path}: unexpected key '${head unexpected}' for type '${t}'"
    && numConstraintsOk
    && strConstraintsOk
    && enumOk
    && itemOk
    && recordOk;

  validateItem =
    path: node:
    let
      item = node.item;
    in
    if isString item then
      abortIf (!(elem item scalarTypes))
        "${fmtPath path}: unknown 'item' type '${item}' (bare item names: ${concatStringsSep ", " scalarTypes})"
    else if isAttrs item then
      let
        t = item.type or null;
      in
      abortIf (t == null) "${fmtPath path}: 'item' descriptor requires a 'type'"
      && abortIf (t != null && !(isString t)) "${fmtPath path}: 'item' type must be a type name string"
      &&
        abortIf
          (
            !(elem t (
              scalarTypes
              ++ [
                "enum"
                "record"
              ]
            ))
          )
          "${fmtPath path}: 'item' type '${t}' is not supported (items may be a scalar type, 'enum', or 'record')"
      && validateLeaf (path ++ [ "item" ]) item
    else
      throw "${fmtPath path}: 'item' must be a bare type name or a descriptor table";

  validateFields =
    path: node:
    foldl' (
      acc: name:
      let
        field = node.fields.${name};
        fpath = path ++ [ name ];
      in
      acc
      && (
        abortIf (
          !(isAttrs field) || !(field ? type)
        ) "${fmtPath fpath}: record field '${name}' must be a typed descriptor (add a 'type')"
        && validateLeaf fpath field
      )
    ) true (attrNames node.fields);

  # --- option type construction ---------------------------------------------

  strConstraints = node: {
    minLen = node.minLength or null;
    maxLen = node.maxLength or null;
    regex = node.regex or null;
  };

  numConstraints = node: {
    min = node.min or null;
    max = node.max or null;
  };

  # Scalar types, with validate.* checks attached where constraints apply. The
  # checks reuse the same path-aware validators as the `mk*Option` family, so a
  # bad value reports `extraOptions.<path>` (and `source`) instead of a bare
  # nixpkgs type error.
  scalarType =
    path: node:
    let
      t = node.type;
    in
    if t == "bool" then
      types.bool
    else if t == "string" then
      types.addCheck types.str (validate.str (strConstraints node) (fmtPath path) source)
    else if t == "number" then
      types.addCheck types.number (validate.float (numConstraints node) (fmtPath path) source)
    else if t == "int" then
      types.addCheck types.int (validate.int (numConstraints node) (fmtPath path) source)
    else if t == "float" then
      # `types.number` (not `types.float`): TOML parses whole numbers as ints,
      # and validate.float already accepts ints — `types.float`'s `isFloat`
      # check would reject them with a bare nixpkgs error before ours ran.
      # Mirrors `mkFloatBetweenOption` in lib/options/helpers.nix.
      types.addCheck types.number (validate.float (numConstraints node) (fmtPath path) source)
    else if t == "nonEmptyString" then
      types.nonEmptyStr
    else if t == "lines" then
      types.lines
    else
      throw "${fmtPath path}: unknown type '${t}'";

  bareItemType =
    path: name:
    if name == "bool" then
      types.bool
    else if name == "string" then
      types.str
    else if name == "number" then
      types.number
    else if name == "int" then
      types.int
    else if name == "float" then
      types.number
    else if name == "nonEmptyString" then
      types.nonEmptyStr
    else if name == "lines" then
      types.lines
    else
      throw "${fmtPath path}: unknown 'item' type '${name}'";

  itemType =
    path: node:
    let
      item = node.item;
    in
    if isString item then bareItemType path item else leafType (path ++ [ "item" ]) item;

  recordFields =
    path: node: mapAttrs (name: field: mkOptionValue (path ++ [ name ]) field) node.fields;

  # The type for a typed leaf: composite types (enum / the *List family /
  # list / attrs / record) plus the scalars.
  leafType =
    path: node:
    let
      t = node.type;
    in
    if t == "enum" then
      types.addCheck types.anything (validate.enum node.choices (fmtPath path) source)
    else if t == "stringList" then
      types.listOf types.str
    else if t == "numberList" then
      types.listOf types.number
    else if t == "intList" then
      types.listOf types.int
    else if t == "floatList" then
      # Same reasoning as scalar `float` (above): TOML parses whole numbers as
      # ints, so a float list must accept ints too or `[1, 2]` gets rejected by
      # `types.float`'s `isFloat` check before our constraints could run.
      types.listOf types.number
    else if t == "list" then
      types.listOf (itemType path node)
    else if t == "attrs" then
      types.attrsOf (itemType path node)
    else if t == "record" then
      types.submodule {
        options = recordFields path node;
      }
    else
      scalarType path node;

  # Fail fast on a bad schema `default` OR a bad injected user value with the
  # same rich, path-aware validator error a constrained scalar would get —
  # surfaces at genflake, before any build. Constraint-carrying types (string /
  # number / int / float / enum) run their `validate.*` validator (which throws
  # the message); every other type falls back to `leafType.check`, which also
  # covers the bool / list / attrs shapes nixpkgs would otherwise only check
  # lazily when the option is read. Composite types are checked ONE level deep:
  # list elements and attrs values against their `item` type, and record fields
  # against their `fields` schema (with undeclared fields rejected), so a bad
  # element/field fails at genflake too — not just a wrong container shape.
  # Record's own `check` accepts any attrset (nixpkgs' submodule check:
  # `isAttrs || isFunction || path.check`), so the shape gate passes and
  # `recordOk` walks the fields; a non-attrs value for a record leaf is still
  # rejected by the shape gate. Nested item/field `record`s are NOT recursively
  # checked here (their submodule types check when forced) — document that limit.
  eagerCheck =
    path: node: value:
    let
      t = node.type;
      rich =
        if t == "string" then
          validate.str (strConstraints node) (fmtPath path) source value
        else if t == "int" then
          validate.int (numConstraints node) (fmtPath path) source value
        else if t == "number" then
          validate.float (numConstraints node) (fmtPath path) source value
        else if t == "float" then
          validate.float (numConstraints node) (fmtPath path) source value
        else if t == "enum" then
          validate.enum node.choices (fmtPath path) source value
        else
          null;

      # The `item` type of a list/attrs leaf (null for scalars/enum/record).
      item =
        if t == "list" || t == "attrs" then
          itemType path node
        else if t == "stringList" then
          types.str
        else if t == "numberList" || t == "floatList" then
          types.number
        else if t == "intList" then
          types.int
        else
          null;

      # Deep check for the composite families. `all`/`filter` over the container
      # is only reached after the container's own `check` passed, so `value` is
      # an attrset for attrs/record and a list for the list family.
      compositeOk =
        if t == "record" then
          let
            valueFields = attrNames value;
            undeclared = filter (k: !(node.fields ? ${k})) valueFields;
          in
          if undeclared != [ ] then
            throw "${fmtPath path}: custom option value has undeclared field${
              if length undeclared > 1 then "s" else ""
            } ${concatStringsSep ", " undeclared} — declared fields: ${concatStringsSep ", " (attrNames node.fields)} (${source})"
          else
            all (k: eagerCheck (path ++ [ k ]) node.fields.${k} value.${k}) valueFields
        else if item != null then
          if t == "attrs" then
            let
              bad = filter (k: !item.check value.${k}) (attrNames value);
            in
            if bad == [ ] then
              true
            else
              throw "${fmtPath path}: custom option value attribute '${head bad}' (${
                builtins.toJSON value.${head bad}
              }) does not match item type '${item.description}' (${source})"
          else
            let
              badIdx = filter (i: !item.check (elemAt value i)) (genList (x: x) (length value));
            in
            if badIdx == [ ] then
              true
            else
              throw "${fmtPath path}: custom option value element ${toString (head badIdx)} (${builtins.toJSON (elemAt value (head badIdx))}) does not match item type '${item.description}' (${source})"
        else
          true;
    in
    if rich != null then
      rich
    else if (leafType path node).check value then
      compositeOk
    else
      throw "${fmtPath path}: custom option value ${builtins.toJSON value} does not match type '${t}' (${source})";

  mkOptionValue =
    path: node:
    let
      # Only set `default` when the schema declares one. nixpkgs feeds
      # `mkOptionDefault opt.default` into the definition list and type-checks it,
      # so an implicit `default = null` on a typed option makes an *unset* option
      # fail as "null doesn't match the type" instead of resolving — and an option
      # the user never touches then aborts the whole build when read. Omitting it
      # gives the standard nixpkgs contract: resolve the user value if set, else
      # "was accessed but has no value defined" (tryEval'd to null in the search index).
      option = mkOption (
        {
          type = leafType path node;
          description = node.description or "";
        }
        // lib.optionalAttrs (node ? default) { default = node.default; }
      );

      defaultOk = if node ? default then eagerCheck path node node.default else true;
    in
    assert defaultOk;
    option;

  # Recursively build the `options` attrset from the schema: namespaces nest,
  # leaves become mkOption values.
  buildTree =
    path: node:
    if node ? type then mkOptionValue path node else mapAttrs (k: v: buildTree (path ++ [ k ]) v) node;

  # Every declared leaf path (as a segment list).
  leafPaths =
    schema:
    let
      go =
        path: node:
        if node ? type then [ path ] else concatMap (k: go (path ++ [ k ]) node.${k}) (attrNames node);
    in
    go [ ] schema;
in
{
  extraOptions = {
    inherit marker;

    # Turn the `[extraOptions]` schema into a NixOS module declaring every
    # option it describes. The root must be a namespace — options are declared
    # at full dotted paths below it, never at the root itself.
    declare =
      schema:
      let
        valid =
          abortIf (
            !(isAttrs schema)
          ) "extraOptions: must be a table of option declarations (got ${builtins.typeOf schema})"
          && abortIf (
            schema ? type
          ) "extraOptions: cannot declare an option at the root — nest declarations in tables"
          && validateNamespace [ ] schema;
      in
      assert valid;
      setDefaultModuleLocation marker {
        options = buildTree [ ] schema;
      };

    # genflake-stage value injection: per-path `config.<path> = <raw value>` for
    # every declared NON-icedos option the user actually set, so the search index
    # shows real values. `icedos.*` options are skipped (their values already
    # flow through the per-file `config.icedos` imports in modules/options.nix),
    # as are paths under `extraOptions` itself (that table holds schema, not
    # values). A declared path that traverses a non-table intermediate aborts
    # loudly instead of degrading to a silent null, and every injected value is
    # eagerly type-checked against its declared leaf — a wrong-typed value fails
    # at genflake, not silently until something reads the option.
    inject =
      schema: userConfig:
      let
        declared = leafPaths schema;

        injectable = filter (
          p:
          p != [ ]
          && !(elem (head p) [
            "icedos"
            "extraOptions"
          ])
        ) declared;

        rawValue =
          full: cur: path:
          let
            seg = head path;
            rest = tail path;
          in
          if path == [ ] then
            {
              found = true;
              value = cur;
            }
          else if !(isAttrs cur) then
            throw "${fmtPath full}: custom option value traverses a non-table value at '${fmtPath path}' — make the intermediate tables match the declared structure"
          else if cur ? ${seg} then
            rawValue full cur.${seg} rest
          else
            { found = false; };

        present = filter (x: x.found) (map (p: (rawValue p userConfig p) // { inherit p; }) injectable);
      in
      map (
        x:
        let
          leaf = getAttrFromPath x.p schema;
        in
        assert eagerCheck x.p leaf x.value;
        setDefaultModuleLocation marker {
          config = setAttrByPath x.p x.value;
        }
      ) present;
  };
}
