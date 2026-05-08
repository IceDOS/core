{ icedosLib, lib, ... }:

let
  inherit (lib) mkOption types;
  inherit (icedosLib) abortIf validate;

  requireArg =
    fnName: args: key:
    abortIf (!(args ? ${key}))
      "${fnName}: missing required arg '${key}' (every validating wrapper requires path + source + default)";

  # validate.* fires on every resolved value — module-config.toml defaults and
  # user overrides alike — so dev typos (bad default in a module's own
  # config.toml) surface with the same rich path/source error as user-side
  # mistakes.
  requireValidationArgs =
    fnName: args:
    requireArg fnName args "path"
    && requireArg fnName args "source"
    && requireArg fnName args "default";

  stripValidationKeys =
    args:
    removeAttrs args [
      "path"
      "source"
    ];
in
rec {
  imports = [ ./validate.nix ];

  mkAttrsOption = args: mkOption (args // { type = types.attrs; });

  mkAttrsOfOption =
    args: valueType:
    let
      cleanArgs = stripValidationKeys args;
    in
    mkOption (cleanArgs // { type = types.attrsOf valueType; });

  mkBoolOption = args: mkOption (args // { type = types.bool; });

  mkEitherOption =
    args: typeA: typeB:
    mkOption (args // { type = types.either typeA typeB; });

  mkEnumOption =
    args: values:
    let
      argsOk = requireValidationArgs "mkEnumOption" args;
      cleanArgs = stripValidationKeys args;
      check = v: validate.enum values args.path args.source v;
    in
    assert argsOk;
    mkOption (cleanArgs // { type = types.addCheck types.anything check; });

  mkFloatBetweenOption =
    args: low: high:
    let
      argsOk = requireValidationArgs "mkFloatBetweenOption" args;
      cleanArgs = stripValidationKeys args;

      check =
        v:
        validate.float {
          min = low;
          max = high;
        } args.path args.source v;
    in
    assert argsOk;
    mkOption (cleanArgs // { type = types.addCheck types.number check; });

  mkFunctionOption =
    args:
    mkOption (
      args
      // {
        type = types.function;
      }
    );

  mkIntBetweenOption =
    args: low: high:
    let
      argsOk = requireValidationArgs "mkIntBetweenOption" args;
      cleanArgs = stripValidationKeys args;
      check =
        v:
        validate.int {
          min = low;
          max = high;
        } args.path args.source v;
    in
    assert argsOk;
    mkOption (cleanArgs // { type = types.addCheck types.int check; });

  mkLinesListOption = args: mkOption (args // { type = with types; listOf lines; });
  mkLinesOption = args: mkOption (args // { type = types.lines; });
  mkListOption = args: subType: mkOption (args // { type = types.listOf subType; });
  mkNonEmptyStrOption = args: mkOption (args // { type = types.nonEmptyStr; });
  mkNullableOption = args: subType: mkOption (args // { type = types.nullOr subType; });
  mkNumberListOption = args: mkOption (args // { type = with types; listOf number; });
  mkNumberOption = args: mkOption (args // { type = types.number; });

  mkRecordOption =
    args: fields:
    let
      cleanArgs = stripValidationKeys (removeAttrs args [ "fields" ]);
    in
    mkOption (
      cleanArgs
      // {
        type = types.submodule {
          options = fields;
        };
      }
    );

  mkStrEnumOption = mkEnumOption;
  mkStrListOption = args: mkOption (args // { type = with types; listOf str; });
  mkStrOption = args: mkOption (args // { type = types.str; });

  mkSubmoduleAttrsOption =
    args: options:
    mkOption (
      args
      // {
        type = types.attrsOf (
          types.submodule {
            inherit options;
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
            inherit options;
          }
        );
      }
    );

  mkSubmoduleOption =
    args: options:
    mkOption (
      args
      // {
        type = types.submodule {
          inherit options;
        };
      }
    );

  mkUsersOption = options: mkSubmoduleAttrsOption { default = { }; } options;
}
