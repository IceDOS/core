{
  config,
  icedosLib,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.icedos) configurationLocation;
  inherit (config.icedos.system) packages;
  inherit (lib) mapAttrs mapAttrsToList;

  inherit (icedosLib.bash)
    prelude
    genHelpFlags
    purpleString
    redString
    ;

  inherit (icedosLib.pkgs) mapper;

  # Wrapper expression so the bash script can evaluate with baked-in
  # configurationLocation and core input paths.
  buildPkgExpr = pkgs.writeText "icedos-build-pkg.nix" ''
    { packagePath, extraArgs ? {} }:
    (import "${inputs.icedos-core}/lib/build-package.nix") {
      stateDir = "${configurationLocation}";
      inherit packagePath extraArgs;
    }
  '';
in
{
  environment.systemPackages = (mapper pkgs packages) ++ [ pkgs.nixfmt ];

  icedos.system.toolset.commands = [
    {
      command = "pkgs";
      help = "print package related commands";
      commands = [
        {
          command = "list";
          script = "nix-store --query --requisites /run/current-system | cut -d- -f2- | sort | uniq";
          help = "list installed packages";
        }
        {
          command = "build";
          help = "build a package.nix — requires prior 'icedos rebuild'";
          script = ''
            ${prelude}

            if [[ ${genHelpFlags { }} ]]; then
              echo "Available arguments:"
              echo -e "> ${purpleString "--path|-p"}: path to a package.nix to build"
              echo -e "> ${purpleString "--run|-r"}: binary name to launch after building"
              echo -e "> ${purpleString "--"}: remaining arguments forwarded to the launched binary"
              echo "The package is evaluated against the system's pkgs (generated"
              echo "flake context) with icedosLib.packaging auto-supplied."
              echo "Run 'icedos rebuild' first if you haven't yet."
              exit 0
            fi

            PATH_ARG=""
            RUN_ARG=""
            declare -a BIN_ARGS=()

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --path|-p)
                  [ $# -ge 2 ] || die "--path requires a value"
                  PATH_ARG="$2"
                  shift 2
                  ;;
                --run|-r)
                  [ $# -ge 2 ] || die "--run requires a value"
                  RUN_ARG="$2"
                  shift 2
                  ;;
                --)
                  shift
                  BIN_ARGS+=("$@")
                  break
                  ;;
                *)
                  echo -e "${redString "Unknown arg"}: $1"
                  exit 1
              esac
            done

            [ -z "$PATH_ARG" ] && echo -e "${redString "error"}: --path|-p is required" && exit 1

            [ ''${#BIN_ARGS[@]} -gt 0 ] && [ -z "$RUN_ARG" ] && echo -e "${redString "error"}: -- requires --run" && exit 1

            if [ ! -f "$PATH_ARG" ]; then
              echo -e "${redString "error"}: file not found — $PATH_ARG"
              exit 1
            fi

            PATH_ARG="$(realpath "$PATH_ARG")"

            if [ ! -f "${configurationLocation}/flake.nix" ]; then
              die "no generated flake at '${configurationLocation}'; run 'icedos rebuild' first."
            fi

            OUT="$(nix-build --no-out-link -E '(import ${buildPkgExpr}) { packagePath = "'"$PATH_ARG"'"; }')" || exit 1
            read -r OUT <<< "$OUT"

            if [ -z "$RUN_ARG" ]; then
              echo "$OUT"
            else
              exec "$OUT/bin/$RUN_ARG" "''${BIN_ARGS[@]}"
            fi
          '';
        }

        {
          command = "run";
          help = "build a nixpkgs attribute and exec its main binary";
          script = ''
            ${prelude}

            export NIXPKGS_ALLOW_UNFREE=1

            if [[ ${genHelpFlags { }} ]]; then
              echo "Available arguments:"
              echo -e "> ${purpleString "<package>"}: nixpkgs attribute name (e.g. firefox, git, nodejs)"
              echo -e "> ${purpleString "-s, --select"}: show binary selector even when a main program is set"
              echo -e "> ${purpleString "-d, --detach"}: detach the launched binary from the terminal"
              echo -e "> ${purpleString "--insecure"}: allow insecure packages"
              echo -e "> ${purpleString "--"}: end of icedos flags; everything after is forwarded to the launched binary"
              echo -e "any positional arguments after ${purpleString "<package>"} are also forwarded to the launched binary"
              exit 0
            fi

            SELECT=0
            DETACH=0
            PACKAGE=""
            declare -a BIN_ARGS=()

            while [[ $# -gt 0 ]]; do
              if [ -n "$PACKAGE" ]; then
                BIN_ARGS+=("$1")
                shift
                continue
              fi

              case "$1" in
                -s|--select)
                  SELECT=1
                  shift
                  ;;
                -d|--detach)
                  DETACH=1
                  shift
                  ;;
                --insecure)
                  export NIXPKGS_ALLOW_INSECURE=1
                  shift
                  ;;
                --)
                  shift
                  BIN_ARGS+=("$@")
                  break
                  ;;
                *)
                  PACKAGE="$1"
                  shift
                  ;;
              esac
            done

            [ -z "$PACKAGE" ] && echo -e "${redString "error"}: package name is required" && exit 1

            run_bin() {
              if [ "$DETACH" -eq 1 ]; then
                setsid -f "$@" </dev/null >/dev/null 2>&1
                exit 0
              fi
              exec "$@"
            }

            if [ "$SELECT" -ne 1 ]; then
              EXE=$(nix eval --raw --impure --expr \
                "(let p = (import <nixpkgs> {}); in p.lib.getExe p.$PACKAGE)" \
                2>/dev/null) || EXE=""

              if [ -n "$EXE" ] && [ -x "$EXE" ]; then
                run_bin "$EXE" "''${BIN_ARGS[@]}"
              fi
            fi

            STORE_PATH=$(nix-build '<nixpkgs>' --no-out-link -A "$PACKAGE" 2>/dev/null) || {
              echo -e "${redString "error"}: failed to build package '$PACKAGE'"
              exit 1
            }

            BIN_DIR="$STORE_PATH/bin"
            if [ ! -d "$BIN_DIR" ]; then
              echo -e "${redString "error"}: '$PACKAGE' has no /bin directory"
              exit 1
            fi

            mapfile -t BINS < <(ls "$BIN_DIR" 2>/dev/null | sort)

            if [ ''${#BINS[@]} -eq 0 ]; then
              echo -e "${redString "error"}: no executables in $BIN_DIR"
              exit 1
            fi

            if [ ''${#BINS[@]} -eq 1 ]; then
              run_bin "$BIN_DIR/''${BINS[0]}" "''${BIN_ARGS[@]}"
            fi

            echo "Binaries in $PACKAGE:"
            PS3="Select binary: "
            select bin in "''${BINS[@]}"; do
              if [ -n "$bin" ]; then
                run_bin "$BIN_DIR/$bin" "''${BIN_ARGS[@]}"
              fi
            done
          '';
        }
      ];
    }

    {
      command = "repair";
      script = "nix-store --verify --check-contents --repair";
      help = "repair nix store";
    }

    {
      command = "shell";
      help = "spawn a nix shell with optimized env";
      script = ''
        ${prelude}

        export NIXPKGS_ALLOW_UNFREE=1

        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Available arguments:"
          echo -e "> ${purpleString "--insecure"}: allow insecure packages"
          exit 0
        fi

        if [ "$1" == "--insecure" ]; then
          export NIXPKGS_ALLOW_INSECURE=1
          shift
        fi

        nix-shell "$@"
      '';
    }
  ];

  nix = {
    # Use flake's nixpkgs input for nix-shell
    nixPath = mapAttrsToList (key: _: "${key}=flake:${key}") config.nix.registry;
    registry = mapAttrs (_: v: { flake = v; }) inputs;

    settings = {
      auto-optimise-store = true;

      experimental-features = [
        "flakes"
        "nix-command"
        "pipe-operators"
      ];

      fallback = true;
    };
  };

  nixpkgs.config = icedosLib.pkgs.mkConfig config.icedos;
}
