# Thin wrapper over repl-context.nix that builds a single package.nix with
# icedosLib.packaging (extractAppImage, installDesktopEntry) injected into
# callPackage's auto-arg scope. Usage:
#
#   nix-build -E '(import <this-file>) { stateDir = "..."; packagePath = ./pkg.nix; }'
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
