# Enumerate + load the ordered set of user config TOML files for a config root:
#
#   [ config.toml, <extra-configs-dir>/*.toml (sorted), … ]
#
# `config.toml` is always the global base; every `*.toml` under each
# `icedos.system.extraConfigs` directory (default `configs`) is autoloaded on
# top of it. Hidden `.<name>.toml` files are included too — they load exactly
# like non-hidden ones (hiding is a gitignore concern, not a loader one), which
# is what makes `configs/.claude.toml` a local-only override.
#
# Per-file opt-out: any extra config file may set a top-level `enable = false`
# to skip loading itself (default `true` = loaded). `config.toml` is the base
# and always loads. `enable` is metadata — it is stripped from the returned
# content so it never reaches the raw NixOS passthrough as `config.enable`.
#
# Returns a list of `{ rel; content; }`: `content` is the parsed TOML (with the
# `enable` toggle removed), `rel` (config-root relative) is for error
# attribution / `setDefaultModuleLocation`.
#
# Kept self-contained (no `icedosLib`/`lib`): this is imported bare by
# `load-user-config.nix`, which itself runs before any icedosLib exists (and is
# re-imported by the generated build flake against `inputs.icedos-config`).
# Both consumers — `load-user-config.nix` and `modules/options.nix` — route
# through here so the loaded file set never drifts between them.
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

  # config.toml is OPTIONAL — a config root may be defined entirely by
  # configs/*.toml and/or modules/. When it is absent, `extraConfigs` falls back
  # to its default and config.toml simply isn't part of the loaded set.
  mainPath = "${configRoot}/config.toml";
  hasMain = pathExists mainPath;
  main = if hasMain then readCfg mainPath else { };

  # Bootstrap value: `extraConfigs` is read from config.toml only (like
  # system.arch / system.version), never from the extra-configs it selects; it
  # defaults when there is no config.toml.
  extraConfigsDirs = main.icedos.system.extraConfigs or [ "configs" ];

  # Every regular `*.toml` directly under `dir`, name-sorted for a deterministic
  # merge order, parsed. Missing dirs contribute nothing.
  tomlFilesIn =
    dir:
    let
      abs = "${configRoot}/${dir}";
    in
    if !(pathExists abs) then
      [ ]
    else
      let
        entries = readDir abs;
        names = sort (a: b: a < b) (
          filter (n: entries.${n} == "regular" && hasSuffix ".toml" n) (attrNames entries)
        );
      in
      map (n: {
        rel = "${dir}/${n}";
        content = readCfg "${abs}/${n}";
      }) names;

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
