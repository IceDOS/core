{
  config,
  icedosLib,
  lib,
  pkgs,
  self,
  ...
}:

let
  inherit (lib) mapAttrs;

  inherit (icedosLib)
    mkBoolOption
    mkFunctionOption
    mkStrOption
    ;

  cfg = config.icedos;

  libFile = import ./lib.nix {
    inherit self pkgs lib;
    config = config.icedos;
  };
in
{
  options.icedos.internals = {
    accentColor = mkStrOption {
      default =
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
          .${cfg.desktop.gnome.accentColor};
    };

    isFirstBuild = mkBoolOption { default = false; };

    icedosLib = mapAttrs (_: v: mkFunctionOption v) libFile;
  };
}
