# The binding set every interactive IceDOS evaluation opens with — `icedos repl`
# (modules/repl.nix) and the MCP server's `nix_eval` tool both import this file,
# so the two can never disagree about what `config`, `pkgs` or `inputs` mean.
#
# Everything is read from the generated flake in the state dir, i.e. the exact
# same evaluation the system was built from (genflake.nix builds `icedosLib` and
# `pkgs` the same way). That is what makes module defaults visible: reading
# config.toml alone only ever shows what the user literally wrote.
#
# Impure by design: `getFlake` and the working-tree read below need the real
# filesystem, which `nix repl` and `nix eval --impure` both provide.
{
  # Config repo root — the directory holding config.toml. Read live, so
  # `declared` reflects pending edits.
  configRoot,
  # Generated state dir (`config.icedos.configurationLocation`), holding the
  # flake.nix/flake.lock that built the current system.
  stateDir,
}:
let
  inherit (builtins)
    attrNames
    getFlake
    head
    readFile
    replaceStrings
    ;

  # `path:` keeps this a plain path flakeref: the state dir lives inside the
  # config git repo, and a bare path would be re-resolved as git+file://…?dir=…
  flake = getFlake "path:${stateDir}";

  inherit (flake) inputs;

  systems = flake.nixosConfigurations;

  # genflake used to name the configuration after /etc/hostname; fall back to the sole
  # entry so a host renamed since the last rebuild still opens a REPL.
  hostname = replaceStrings [ "\n" ] [ "" ] (readFile "/etc/hostname");

  system =
    if systems ? "icedos" then
      systems.icedos
    else if systems ? ${hostname} then
      systems.${hostname}
    else if systems != { } then
      systems.${head (attrNames systems)}
    else
      throw "no nixosConfigurations in '${stateDir}'; run 'icedos rebuild' first";

  pkgs = system.pkgs;
  lib = pkgs.lib;

  # Raw merged TOML from the working tree — what you are *about* to build, as
  # opposed to `config`, which is what the running system was built from. Same
  # split `icedos configuration diff` reports on.
  declared = (import "${inputs.icedos-core}/lib/load-user-config.nix" configRoot).icedos;

  # Mirrors genflake.nix's build-stage instantiation exactly, including the real
  # `inputs`: without them every member that resolves a module repo throws.
  icedosLib = import "${inputs.icedos-core}/lib" {
    inherit lib pkgs inputs;
    config = declared;
    self = toString inputs.icedos-core;
  };
in
{
  inherit
    declared
    icedosLib
    inputs
    lib
    pkgs
    ;

  inherit (system) config options;
}
