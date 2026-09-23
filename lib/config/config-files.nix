# The ordered user config set -> [ { rel; content; } ]: config.toml, then every
# `*.toml` (hidden included, `enable = false` skipped) under extraConfigs, recursively.
configRoot:
let
  inherit (builtins)
    attrNames
    concatMap
    filter
    fromTOML
    pathExists
    readDir
    readFile
    removeAttrs
    sort
    stringLength
    substring
    ;

  hasSuffix =
    suffix: str:
    let
      sl = stringLength suffix;
      l = stringLength str;
    in
    l >= sl && substring (l - sl) sl str == suffix;

  readCfg = abs: fromTOML (readFile abs);

  # Optional: a config root may be defined entirely by configs/*.toml or modules/.
  mainPath = "${configRoot}/config.toml";
  hasMain = pathExists mainPath;
  main = if hasMain then readCfg mainPath else { };

  # Bootstrap value: read from config.toml only, never from the files it selects.
  extraConfigsDirs = main.icedos.system.extraConfigs or [ "configs" ];

  # Every regular `*.toml` under `dir`, recursing into subdirectories, parsed.
  # Sorted by relative path for a deterministic merge order. Missing dirs contribute nothing.
  tomlFilesIn =
    dir:
    let
      abs = "${configRoot}/${dir}";
      entries = readDir abs;
      names = attrNames entries;

      files = map (n: {
        rel = "${dir}/${n}";
        content = readCfg "${abs}/${n}";
      }) (filter (n: entries.${n} == "regular" && hasSuffix ".toml" n) names);

      subdirs = filter (n: entries.${n} == "directory") names;
    in
    if !(pathExists abs) then
      [ ]
    else
      sort (a: b: a.rel < b.rel) (files ++ concatMap (n: tomlFilesIn "${dir}/${n}") subdirs);

  # Extra config files. A top-level `enable = false` drops the file (default:
  # loaded). config.toml (the base) is never subject to this gate.
  enabledExtra = filter (e: (e.content.enable or true) != false) (
    concatMap tomlFilesIn extraConfigsDirs
  );

  baseEntries =
    if hasMain then
      [
        {
          rel = "config.toml";
          content = main;
        }
      ]
    else
      [ ];

  entries = baseEntries ++ enabledExtra;
in
# Strip the `enable` toggle so it never reaches config (raw NixOS passthrough).
map (e: {
  inherit (e) rel;
  content = removeAttrs e.content [ "enable" ];
}) entries
