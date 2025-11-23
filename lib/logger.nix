{ icedosLib, lib, ... }:

let
  inherit (builtins) attrNames trace toJSON;
  inherit (icedosLib) ENABLE_LOGGING ICEDOS_STAGE;
in
rec {
  log =
    value: cb: if (ENABLE_LOGGING) then trace "${ICEDOS_STAGE}: ${toJSON (cb value)}" value else value;

  logValue = value: log value (_: value);
  logAttrKeys = value: log value (attrNames value);
}
