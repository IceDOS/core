{ config, ... }:

let
  inherit (builtins) attrNames foldl' toJSON;

  mkFiles =
    files:
    foldl' (
      acc: fileName:
      acc
      // {
        "icedos/${fileName}" = {
          mode = "0444";
        }
        // files.${fileName};
      }
    ) { } (attrNames files);
in
{
  environment.etc = mkFiles {
    "substituters".text = toJSON (with config.nix.settings; substituters ++ trusted-substituters);
  };
}
