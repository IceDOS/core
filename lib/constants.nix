{
  enableLogging ? false,
  githubViaSsh ? null,
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

  # Tri-state override for `icedos.system.githubViaSsh`; `null` = nothing
  # overrides the option. `--github-ssh`/`--no-github-ssh` set ICEDOS_GITHUB_SSH
  # to "1"/"0", and genflake bakes the value it resolved into the generated
  # flake's lib import (like enableLogging) because the env var does not survive
  # into the build stage's pure eval — without the bake, the build stage would
  # silently fall back to the option and disagree with the urls already emitted.
  GITHUB_VIA_SSH_BAKED =
    if githubViaSsh != null then
      githubViaSsh
    else
      let
        env = getEnv "ICEDOS_GITHUB_SSH";
      in
      if env == "1" then
        true
      else if env == "0" then
        false
      else
        null;

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
