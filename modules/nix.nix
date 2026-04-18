{
  config,
  icedosLib,
  inputs,
  lib,
  ...
}:

let
  inherit (lib) mapAttrs mapAttrsToList;
  inherit (icedosLib)
    colorBashHeader
    helpFlags
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
            ${colorBashHeader}

            if [[ ${helpFlags} ]]; then
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
        ${colorBashHeader}

        export NIXPKGS_ALLOW_UNFREE=1

        if [[ ${helpFlags} ]]; then
          echo "Available arguments:"
          echo -e "> ${purpleString "--insecure"}: allow insecure packages"
          exit 0
        fi

        if [ "$1" == "--insecure" ]; then
          export NIXPKGS_ALLOW_INSECURE=1
          shift
        fi

        nix-shell $@
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
