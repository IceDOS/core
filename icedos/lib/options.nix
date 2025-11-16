{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  mkBoolOption = args: mkOption (args // { type = types.bool; });
  mkLinesOption = args: mkOption (args // { type = types.lines; });
  mkNumberOption = args: mkOption (args // { type = types.number; });
  mkStrListOption = args: mkOption (args // { type = with types; listOf str; });
  mkStrOption = args: mkOption (args // { type = types.str; });

  mkFunctionOption =
    args:
    mkOption (
      args
      // {
        type = types.function;
      }
    );

  mkSubmoduleAttrsOption =
    args: options:
    mkOption (
      args
      // {
        type = types.attrsOf (
          types.submodule {
            options = options;
          }
        );
      }
    );

  mkSubmoduleListOption =
    args: options:
    mkOption (
      args
      // {
        type = types.listOf (
          types.submodule {
            options = options;
          }
        );
      }
    );
}
