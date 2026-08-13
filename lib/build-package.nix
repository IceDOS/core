# Builds one package.nix on the repl-context scope, with icedosLib.packaging in
# callPackage's args. `packagePath` MUST arrive via --argstr, never interpolated.
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
