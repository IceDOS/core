{
  enableLogging ? false,
  ...
}:
let
  inherit (builtins) getEnv;
in
{
  INPUTS_PREFIX = "icedos";

  # Default GitHub-token file for nix github.com fetches. build/main.py keeps its
  # own copy (it cannot read this Nix constant).
  GITHUB_TOKEN_PATH = "/etc/icedos-github-token";
  ENABLE_LOGGING = enableLogging || (getEnv "ICEDOS_LOGGING") == "1";

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
