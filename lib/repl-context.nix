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
    ;

  # `path:` keeps this a plain path flakeref: the state dir lives inside the
  # config git repo, and a bare path would be re-resolved as git+file://…?dir=…
  flake = getFlake "path:${stateDir}";

  inherit (flake) inputs;

  systems = flake.nixosConfigurations;

  # genflake emits exactly one nixosConfiguration per generated flake, so the
  # sole entry is deterministic — no need to know its name.
  system =
    if systems != { } then
      systems.${head (attrNames systems)}
    else
      throw "no nixosConfigurations in '${stateDir}'; run 'icedos rebuild' first";

  pkgs = system.pkgs;
  lib = pkgs.lib;

  # Raw merged TOML from the working tree — what you are *about* to build, as
  # opposed to `config`, which is what the running system was built from. Same
  # split `icedos configuration diff` reports on.
  declared = (import "${inputs.icedos-core}/lib/load-user-config.nix" configRoot).icedos;
in
{
  inherit
    declared
    inputs
    lib
    pkgs
    ;

  # The module-facing lib, as the generated flake exported it: base icedosLib
  # merged with every module's top-level `lib` field contribution, computed by
  # `modulesFromConfig` over the built closure and shared with
  # `specialArgs.icedosLib` within the one flake evaluation — so `icedos repl`
  # and the MCP `nix_eval` tool see exactly what a module sees (the same
  # merged value the module system used, not a recomputed fold over the
  # working tree).
  icedosLib =
    flake.icedosLib
      or (throw "no 'icedosLib' output in '${stateDir}'; run 'icedos rebuild' to regenerate the state flake");

  inherit (system) config options;
}
