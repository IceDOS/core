# The bindings `icedos repl` and the MCP `nix_eval` tool both open with, read from
# the generated flake so they show the built evaluation, not just config.toml.
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

  # What you are ABOUT to build, as opposed to `config` (what the running system
  # was built from) — the split `icedos configuration diff` reports on.
  declared = (import "${inputs.icedos-core}/lib/config/load-user-config.nix" configRoot).icedos;
in
{
  inherit
    declared
    inputs
    lib
    pkgs
    ;

  # The merged lib exactly as the generated flake exported it, so repl and
  # `nix_eval` see what a module sees, not a recomputed fold.
  icedosLib =
    flake.icedosLib
      or (throw "no 'icedosLib' output in '${stateDir}'; run 'icedos rebuild' to regenerate the state flake");

  inherit (system) config options;
}
