{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  inherit (lib) mapAttrs mkOption types;
  cfg = config.icedos;

  mkStrOption =
    default:
    mkOption {
      type = types.str;
      default = default;
    };

  mkBoolOption = default: mkOption { type = types.bool; };

  mkFunctionOption =
    default:
    mkOption {
      type = types.function;
      default = default;
    };

  mkSubmoduleListOption =
    options:
    mkOption {
      type = types.listOf (
        types.submodule {
          options = options;
        }
      );
    };

  libFile = import ./lib.nix { inherit self pkgs lib; config = config.icedos; };
in
{
  options.icedos.internals = {
    accentColor = mkStrOption (
      if (!cfg.desktop.gnome.enable) then
        "#${cfg.desktop.accentColor}"
      else
        {
          blue = "#3584e4";
          green = "#3a944a";
          orange = "#ed5b00";
          pink = "#d56199";
          purple = "#9141ac";
          red = "#e62d42";
          slate = "#6f8396";
          teal = "#2190a4";
          yellow = "#c88800";
        }
        .${cfg.desktop.gnome.accentColor}
    );

    isFirstBuild = mkBoolOption (false);

    toolset.commands = mkSubmoduleListOption ({
      bin = mkStrOption ("");
      command = mkStrOption ("");
      help = mkStrOption ("");
    });

    icedosLib = mapAttrs (_: v: mkFunctionOption v) libFile;
  };
}
