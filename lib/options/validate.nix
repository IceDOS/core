{ icedosLib, lib, ... }:

let
  inherit (icedosLib) abortIf;

  inherit (builtins)
    all
    attrNames
    elemAt
    isAttrs
    isFloat
    isInt
    isList
    isString
    length
    match
    stringLength
    typeOf
    ;

  inherit (lib) concatStringsSep elem range;

  fmtPath = path: if path == null then "<unknown path>" else path;
  fmtSource = source: if source == null then "" else "\n  source: ${toString source}";
  fmtVal =
    v:
    if isAttrs v then
      "<attrs>"
    else if isList v then
      "<list>"
    else
      toString v;

  validateInt =
    {
      min ? null,
      max ? null,
    }:
    path: source: value:
    abortIf (
      !isInt value
    ) "${fmtPath path}: expected int, got ${typeOf value} '${fmtVal value}'${fmtSource source}"
    &&
      abortIf (min != null && value < min)
        "${fmtPath path}: ${toString value} below min ${toString min}${fmtSource source}\n  fix: use value >= ${toString min}"
    &&
      abortIf (max != null && value > max)
        "${fmtPath path}: ${toString value} above max ${toString max}${fmtSource source}\n  fix: use value <= ${toString max}";

  validateFloat =
    {
      min ? null,
      max ? null,
    }:
    path: source: value:
    abortIf (
      !isFloat value && !isInt value
    ) "${fmtPath path}: expected number, got ${typeOf value} '${fmtVal value}'${fmtSource source}"
    &&
      abortIf (min != null && value < min)
        "${fmtPath path}: ${toString value} below min ${toString min}${fmtSource source}\n  fix: use value >= ${toString min}"
    &&
      abortIf (max != null && value > max)
        "${fmtPath path}: ${toString value} above max ${toString max}${fmtSource source}\n  fix: use value <= ${toString max}";

  validateEnum =
    choices: path: source: value:
    abortIf (!elem value choices)
      "${fmtPath path}: '${fmtVal value}' not in [${concatStringsSep ", " (map toString choices)}]${fmtSource source}\n  fix: use one of the listed choices";

  validateStr =
    {
      minLen ? null,
      maxLen ? null,
      regex ? null,
    }:
    path: source: value:
    abortIf (
      !isString value
    ) "${fmtPath path}: expected string, got ${typeOf value} '${fmtVal value}'${fmtSource source}"
    &&
      abortIf (minLen != null && stringLength value < minLen)
        "${fmtPath path}: length ${toString (stringLength value)} below minLen ${toString minLen}${fmtSource source}"
    &&
      abortIf (maxLen != null && stringLength value > maxLen)
        "${fmtPath path}: length ${toString (stringLength value)} above maxLen ${toString maxLen}${fmtSource source}"
    && abortIf (
      regex != null && match regex value == null
    ) "${fmtPath path}: '${value}' does not match regex '${regex}'${fmtSource source}";

  validateNonEmpty =
    path: source: value:
    let
      empty =
        if isString value then
          stringLength value == 0
        else if isList value then
          length value == 0
        else if isAttrs value then
          length (attrNames value) == 0
        else
          false;
    in
    abortIf empty "${fmtPath path}: must be non-empty${fmtSource source}";

  validateList =
    {
      itemValidator ? null,
      minLen ? null,
      maxLen ? null,
    }:
    path: source: value:
    abortIf (
      !isList value
    ) "${fmtPath path}: expected list, got ${typeOf value} '${fmtVal value}'${fmtSource source}"
    &&
      abortIf (minLen != null && length value < minLen)
        "${fmtPath path}: length ${toString (length value)} below minLen ${toString minLen}${fmtSource source}"
    &&
      abortIf (maxLen != null && length value > maxLen)
        "${fmtPath path}: length ${toString (length value)} above maxLen ${toString maxLen}${fmtSource source}"
    && (
      if itemValidator == null then
        true
      else if length value == 0 then
        true
      else
        all (
          idx:
          let
            item = elemAt value idx;
          in
          itemValidator "${fmtPath path}[${toString idx}]" source item
        ) (range 0 (length value - 1))
    );

  validateRequires =
    {
      when,
      require,
      path,
      msg,
    }:
    abortIf (when && !require) "${fmtPath path}: ${msg}";

  validateAbort =
    {
      when,
      path,
      msg,
    }:
    abortIf when "${fmtPath path}: ${msg}";
in
{
  validate = {
    int = validateInt;
    float = validateFloat;
    enum = validateEnum;
    str = validateStr;
    nonEmpty = validateNonEmpty;
    list = validateList;
    requires = validateRequires;
    abort = validateAbort;
  };
}
