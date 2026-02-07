_:
let
  inherit (builtins) getEnv;
in
{
  INPUTS_PREFIX = "icedos";
  ENABLE_LOGGING = if ((getEnv "ICEDOS_LOGGING") == "1") then true else false;

  ICEDOS_CONFIG_ROOT = getEnv "ICEDOS_CONFIG_ROOT";
  ICEDOS_ROOT = getEnv "ICEDOS_ROOT";
  ICEDOS_STATE_DIR = getEnv "ICEDOS_STATE_DIR";

  ICEDOS_STAGE =
    let
      stage = getEnv "ICEDOS_STAGE";
    in
    if stage != "" then stage else "nixos_build";
}
