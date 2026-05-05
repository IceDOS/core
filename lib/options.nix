{ lib, ... }:

let
  inherit (lib) mkOption types;
in
rec {
  mkAttrsOption = args: mkOption (args // { type = types.attrs; });
  mkBoolOption = args: mkOption (args // { type = types.bool; });
  mkLinesOption = args: mkOption (args // { type = types.lines; });
  mkLinesListOption = args: mkOption (args // { type = with types; listOf lines; });
  mkNumberOption = args: mkOption (args // { type = types.number; });
  mkNumberListOption = args: mkOption (args // { type = with types; listOf number; });
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

  mkUsersOption = options: mkSubmoduleAttrsOption { default = { }; } options;
  mkListOption = args: subType: mkOption (args // { type = types.listOf subType; });

  mkSubmoduleOption =
    args: options:
    mkOption (
      args
      // {
        type = types.submodule {
          options = options;
        };
      }
    );

  mkEnumOption = args: values: mkOption (args // { type = types.enum values; });

  mkIntBetweenOption =
    args: low: high:
    mkOption (args // { type = types.ints.between low high; });

  mkEitherOption =
    args: typeA: typeB:
    mkOption (args // { type = types.either typeA typeB; });

  mkNonEmptyStrOption = args: mkOption (args // { type = types.nonEmptyStr; });
  mkUntypedOption = args: mkOption args;
}
