_:
let
  inherit (builtins) getEnv;
in
{
  INPUTS_PREFIX = "icedos";
  ENABLE_LOGGING = (getEnv "ICEDOS_LOGGING") == "1";

  ICEDOS_CONFIG_ROOT = getEnv "ICEDOS_CONFIG_ROOT";
  ICEDOS_FLAKE_INPUTS = getEnv "ICEDOS_FLAKE_INPUTS";
  ICEDOS_ROOT = getEnv "ICEDOS_ROOT";
  ICEDOS_STATE_DIR = getEnv "ICEDOS_STATE_DIR";

  ICEDOS_STAGE =
    let
      stage = getEnv "ICEDOS_STAGE";
    in
    if stage != "" then stage else "nixos_build";
}
