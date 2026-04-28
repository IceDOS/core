{
  config,
  icedosLib,
  inputs,
  lib,
  ...
}:

let
  inherit (lib) mapAttrs mapAttrsToList;

  inherit (icedosLib.bash)
    prelude
    genHelpFlags
    purpleString
    redString
    ;
in
{
  icedos.applications.toolset.commands = [
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
          help = "build provided package derivation";
          script = ''
            ${prelude}

            if [[ ${genHelpFlags { }} ]]; then
              echo "Available arguments:"
              echo -e "> ${purpleString "--run|-r"}: provide binary name to launch after building"
              echo -e "> ${purpleString "--path|-p"}: provide nix derivation path to build"
              exit 0
            fi

            while [[ $# -gt 0 ]]; do
              case "$1" in
                --path|-p)
                  BUILD="nix-build -E '(import <nixpkgs> {}).callPackage $2 {}'"
                  shift 2
                  ;;
                --run|-r)
                  RUN="| xargs -I {} bash -c '{}/bin/$2'"
                  shift 2
                  ;;
                *)
                  echo -e "${redString "Unknown arg"}: $1"
                  exit 1
              esac
            done

            [ "$BUILD" == "" ] && echo -e "${redString "error"}: --path|-p is required" && exit 1

            bash -c "$BUILD $RUN"
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
              echo -e "> ${purpleString "--insecure"}: allow insecure packages"
              echo -e "> ${purpleString "--"}: end of icedos flags; everything after is forwarded to the launched binary"
              exit 0
            fi

            SELECT=0
            PACKAGE=""
            declare -a BIN_ARGS=()

            while [[ $# -gt 0 ]]; do
              case "$1" in
                -s|--select)
                  SELECT=1
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
                  if [ -z "$PACKAGE" ]; then
                    PACKAGE="$1"
                  else
                    BIN_ARGS+=("$1")
                  fi
                  shift
                  ;;
              esac
            done

            [ -z "$PACKAGE" ] && echo -e "${redString "error"}: package name is required" && exit 1

            if [ "$SELECT" -ne 1 ]; then
              EXE=$(nix eval --raw --impure --expr \
                "(let p = (import <nixpkgs> {}); in p.lib.getExe p.$PACKAGE)" \
                2>/dev/null) || EXE=""

              if [ -n "$EXE" ] && [ -x "$EXE" ]; then
                exec "$EXE" "''${BIN_ARGS[@]}"
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
              exec "$BIN_DIR/''${BINS[0]}" "''${BIN_ARGS[@]}"
            fi

            echo "Binaries in $PACKAGE:"
            PS3="Select binary: "
            select bin in "''${BINS[@]}"; do
              if [ -n "$bin" ]; then
                exec "$BIN_DIR/$bin" "''${BIN_ARGS[@]}"
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
    };
  };

  nixpkgs.config.allowUnfree = true;
}
