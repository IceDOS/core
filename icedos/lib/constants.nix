_: {
  INPUTS_PREFIX = "icedos";
  ENABLE_LOGGING = false;

  ICEDOS_STAGE =
    let
      stage = builtins.getEnv "ICEDOS_STAGE";
    in
    if stage != "" then stage else "nixos_build";
}
