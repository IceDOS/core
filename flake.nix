{
  inputs = {
    cache-server = {
      flake = false;
      url = "github:icedos/cache-server";
    };

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
          inherit (builtins) isString pathExists;
          isFlake = value: (value._type or null) == "flake";

          # config.toml is optional — a config root may be defined entirely by
          # configs/*.toml and/or modules/. The flake itself (flake.nix) is the
          # marker that identifies the root.
          _configRoot =
            if ((isFlake configRoot) && (pathExists "${configRoot}/flake.nix")) then
              configRoot
            else
              (throw "The value of `configRoot` is invalid. Please set `configRoot = self;`.");

          _stateDir =
            if (isString stateDir) then stateDir else (throw "The value of `stateDir` should be a string.");

          inherit (import ./lib/load-user-config.nix _configRoot) icedos;

          system = icedos.system.arch or "x86_64-linux";
          pkgs = nixpkgs.legacyPackages.${system};

          inherit (pkgs) lib writeShellScript;
          inherit (lib) makeBinPath;

          icedosBuild = toString (
            writeShellScript "icedos-build" ''
              set -e

              export PATH="${
                with pkgs;
                makeBinPath [
                  git
                  jq
                  jsonfmt
                  nh
                  nix
                  nixfmt
                  rsync
                  toml2json
                ]
              }:$PATH"

              export ICEDOS_ROOT="${self}"
              export ICEDOS_CONFIG_ROOT="$PWD"
              export ICEDOS_STATE_DIR="$PWD/${_stateDir}"
              mkdir -p "$ICEDOS_STATE_DIR"

              [ -f "$ICEDOS_STATE_DIR/build.sh" ] && rm "$ICEDOS_STATE_DIR/build.sh"
              echo "#!/usr/bin/env bash" >>"$ICEDOS_STATE_DIR/build.sh"
              echo "set -e" >>"$ICEDOS_STATE_DIR/build.sh"
              echo "cd \"$PWD\"" >>"$ICEDOS_STATE_DIR/build.sh"
              echo "nix run path:. -- \"\$@\"" >>"$ICEDOS_STATE_DIR/build.sh"

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
