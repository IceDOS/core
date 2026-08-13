{
  inputs = {
    cache-server = {
      flake = false;
      url = "github:icedos/cache-server";
    };

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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

          # config.toml is optional; flake.nix is what marks the config root.
          _configRoot =
            if ((isFlake configRoot) && (pathExists "${configRoot}/flake.nix")) then
              configRoot
            else
              (throw "The value of `configRoot` is invalid. Please set `configRoot = self;`.");

          _stateDir =
            if (isString stateDir) then stateDir else (throw "The value of `stateDir` should be a string.");

          inherit (import ./lib/config/load-user-config.nix _configRoot) icedos;

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
                  util-linux
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

          devShells.${system}.default = pkgs.mkShell {
            packages = [ pkgs.nix ];

            shellHook = ''
              source ${self}/lib/prelude.sh

              icedos() {
                if [ "$1" != "rebuild" ]; then
                  echo "Available commands:"
                  echo -e "> ''${PURPLE}rebuild''${NC}           rebuild the system"
                  return 1
                fi
                shift
                local dir=""
                local args=()
                while [[ $# -gt 0 ]]; do
                  case "$1" in
                    --dir) dir="$2"; shift 2 ;;
                    *) args+=("$1"); shift ;;
                  esac
                done
                if [ -n "$dir" ]; then
                  cd "$dir" || return 1
                fi
                nix run path:. -- "''${args[@]}"
              }

              export -f icedos
            '';
          };
        };

      # Eval-only lib tests (`tests/tests.nix`) as a flake check. Any result
      # value other than "ok" fails the derivation.
      checks =
        let
          inherit (nixpkgs) lib;
        in
        lib.genAttrs lib.systems.flakeExposed (
          system:
          let
            pkgs = nixpkgs.legacyPackages.${system};

            # tryEval each result so a test that throws lands in the readable
            # failure list instead of aborting `nix flake check` with an eval trace.
            results = lib.mapAttrs (
              name: value:
              let
                r = builtins.tryEval value;
              in
              if r.success then r.value else "FAIL: ${name} threw during evaluation"
            ) (import ./tests/tests.nix { inherit (pkgs) lib; });

            failures = lib.filterAttrs (_: value: value != "ok") results;
          in
          {
            lib-tests = pkgs.runCommand "icedos-lib-tests" { } (
              if failures == { } then
                "echo 'lib tests: all ok'\ntouch $out"
              else
                lib.concatStringsSep "\n" (
                  [
                    "echo 'lib tests FAILED:' >&2"
                  ]
                  ++ (lib.mapAttrsToList (
                    name: value: "echo ${lib.escapeShellArg "  ${name}: ${value}"} >&2"
                  ) failures)
                  ++ [ "exit 1" ]
                )
            );
          }
        );
    };
}
