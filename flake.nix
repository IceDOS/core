{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      nixpkgs,
      self,
      ...
    }:
    {
      lib.mkIceDOS =
        {
          configRoot,
          stateDir ? ".state",
        }:
        let
          inherit (builtins)
            isString
            pathExists
            readFile
            throw
            ;

          isFlake = value: (value._type or null) == "flake";

          _configRoot =
            if
              (
                (isFlake configRoot)
                && (pathExists "${configRoot}/flake.nix")
                && (pathExists "${configRoot}/config.toml")
              )
            then
              configRoot
            else
              (throw "The value of `configRoot` is invalid. Please set `configRoot = self;`.");

          _stateDir =
            if (isString stateDir) then (stateDir) else (throw "The value of `stateDir` should be a string.");

          inherit (fromTOML (readFile "${_configRoot}/config.toml")) icedos;

          system = icedos.system.arch or "x86_64-linux";
          pkgs = nixpkgs.legacyPackages.${system};

          inherit (pkgs)
            git
            lib
            nh
            nix
            nixfmt
            rsync
            writeShellScript
            ;

          inherit (lib) makeBinPath;

          icedosBuild = toString (
            writeShellScript "icedos-build" ''
              set -e

              export PATH="${
                makeBinPath [
                  git
                  nh
                  nix
                  nixfmt
                  rsync
                ]
              }:$PATH"
              export ICEDOS_ROOT="${self}"
              export ICEDOS_CONFIG_FLAKE="${_configRoot}"
              export ICEDOS_CONFIG_ROOT="$PWD"
              export ICEDOS_STATE_DIR="$PWD/${_stateDir}"
              mkdir -p "$ICEDOS_STATE_DIR"

              [ -f "$ICEDOS_STATE_DIR/build.sh" ] && rm "$ICEDOS_STATE_DIR/build.sh"
              echo "#!/usr/bin/env bash" >>"$ICEDOS_STATE_DIR/build.sh"
              echo "set -e" >>"$ICEDOS_STATE_DIR/build.sh"
              echo "cd \"$PWD\"" >>"$ICEDOS_STATE_DIR/build.sh"
              echo "nix run . -- \"\$@\"" >>"$ICEDOS_STATE_DIR/build.sh"

              bash "${self}/build.sh" "$@"
            ''
          );
        in
        {
          apps.${system}.default = {
            type = "app";
            program = icedosBuild;
          };
        };
    };
}
