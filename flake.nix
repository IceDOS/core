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
        { configRoot, stateDir ? ".state" }:
        let
          inherit (builtins) readFile;
          inherit (fromTOML (readFile "${configRoot}/config.toml")) icedos;

          system = icedos.system.arch or "x86_64-linux";
          pkgs = nixpkgs.legacyPackages.${system};

          inherit (pkgs)
            git
            lib
            nh
            nix
            nixfmt-rfc-style
            rsync
            writeShellScript
            ;

          inherit (lib) makeBinPath;

          icedosBuild = toString (writeShellScript "icedos-build" ''
            set -e

            export PATH="${makeBinPath [ git nh nix nixfmt-rfc-style rsync ]}:$PATH"
            export ICEDOS_ROOT="${self}"
            export ICEDOS_CONFIG_ROOT="$PWD"
            export ICEDOS_STATE_DIR="$PWD/${stateDir}"
            mkdir -p "$ICEDOS_STATE_DIR"

            [ -f "$ICEDOS_STATE_DIR/build.sh" ] && rm "$ICEDOS_STATE_DIR/build.sh"
            echo "#!/usr/bin/env bash" >>"$ICEDOS_STATE_DIR/build.sh"
            echo "set -e" >>"$ICEDOS_STATE_DIR/build.sh"
            echo "cd \"$PWD\"" >>"$ICEDOS_STATE_DIR/build.sh"
            echo "nix run . -- \"\$@\"" >>"$ICEDOS_STATE_DIR/build.sh"

            bash "${self}/build.sh" "$@"
          '');
        in
        {
          apps.${system}.default = {
            type = "app";
            program = icedosBuild;
          };
        };
    };
}
