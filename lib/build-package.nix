# Thin wrapper over repl-context.nix that builds a single package.nix with
# icedosLib.packaging (extractAppImage, installDesktopEntry) injected into
# callPackage's auto-arg scope. Usage (from modules/nix.nix):
#
#   nix-build --no-out-link --argstr packagePath "$PATH_ARG" -E '(import <this-file>)'
#
# nix-build auto-calls the imported function; stateDir is baked into the
# wrapper and packagePath arrives via --argstr (never string-interpolated, so
# the caller's value can't inject Nix code). Do not regress to the old
# explicit-application form `{ stateDir = "..."; packagePath = "'"$PATH_ARG"'"; }`
# — that interpolated `$PATH_ARG` into the expression text.
#
# Reuses repl-context.nix so the getFlake/hostname/icedosLib instantiation
# logic is never duplicated between repl, nix_eval (MCP) and pkgs build.
{
  stateDir,
  packagePath,
  extraArgs ? { },
}:
let
  ctx = import ./repl-context.nix {
    configRoot = "${stateDir}/..";
    inherit stateDir;
  };
in
(ctx.pkgs.extend (final: prev: ctx.icedosLib.packaging)).callPackage packagePath extraArgs
