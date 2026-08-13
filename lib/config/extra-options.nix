# `[extraOptions]` TOML -> a NixOS module declaring those options. A node with a
# `type` is a typed leaf, one without is a namespace; paths are full dotted paths.
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

  # Lands in every generated module's `_file`, so optionsDoc can keep-filter on it
  # and errors name the config files. Also the validate.* `source`.
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

  # Scalar types a `list`/`attrs` `item` may name directly; anything constrained
  # is written as a descriptor table instead.
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

  # Every field of a typed leaf must be a known meta key. The item/fields
  # descriptors are validated by their own recursions.
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

  # The same path-aware validators the `mk*Option` family uses, so a bad value
  # reports `extraOptions.<path>` instead of a bare nixpkgs type error.
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
      # `types.number`, not `types.float`: TOML parses whole numbers as ints and
      # `isFloat` would reject them before our validator ran.
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
      # Same as scalar `float`: `[1, 2]` is a list of ints in TOML.
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

  # Eager, path-aware check of a schema default or injected value at genflake.
  # Composites are checked ONE level deep; nested records check when forced.
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

      # Only reached after the container's own `check` passed, so `value` already
      # has the right shape.
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
      # Only when the schema declares one: an implicit `default = null` is fed
      # through the type check and fails every unset typed option.
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

    # Schema -> a module declaring every option. The root must be a namespace.
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

    # Genflake-stage `config.<path> = <value>` for every declared non-icedos
    # option the user set (icedos.* already flow through the config imports).
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
