{
  icedosLib,
  lib,
  self,
  ...
}:

rec {
  color = {
    hexToRgbInts =
      hex:
      let
        inherit (lib) fromHexString removePrefix;
        inherit (builtins) substring;
        h = removePrefix "#" hex;
      in
      [
        (fromHexString (substring 0 2 h))
        (fromHexString (substring 2 2 h))
        (fromHexString (substring 4 2 h))
      ];
  };

}
