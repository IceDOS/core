{
  icedosLib,
  inputs,
  lib,
  ...
}:

let
  inherit (lib) readFile types;

  inherit (icedosLib)
    mkBoolOption
    mkEitherOption
    mkLinesListOption
    mkLinesOption
    mkListOption
    mkNumberOption
    mkStrListOption
    mkStrOption
    mkSubmoduleAttrsOption
    mkSubmoduleListOption
    mkSubmoduleOption
    ;

  toolsetCommandType = types.submodule {
    options = {
      command = mkStrOption { };
      help = mkStrOption { };

      bin = mkStrOption { default = ""; };

      script = mkLinesOption { default = ""; };

      commands = mkListOption { default = [ ]; } toolsetCommandType;

      completion = mkSubmoduleOption { default = { }; } {
        files = mkBoolOption { default = false; };
      };
    };
  };
in
{
  options = {
    icedos = {
      applications.nh.gc = {
        automatic = mkBoolOption { default = true; };
        days = mkNumberOption { default = 0; };
        generations = mkNumberOption { default = 10; };
        interval = mkStrOption { default = "Mon *-*-* 00:00:00"; };

        hooks = {
          preGc = mkLinesListOption { default = [ ]; };
          postGc = mkLinesListOption { default = [ ]; };
        };
      };

      applications.toolset = {
        commands = mkListOption { default = [ ]; } toolsetCommandType;
        desktopEntries = mkBoolOption { default = false; };
        sessionCommands = mkListOption { default = [ ]; } toolsetCommandType;

        rebuild.hooks = {
          preRebuild = mkLinesListOption { default = [ ]; };
          postRebuild = mkLinesListOption { default = [ ]; };
          preUpdate = mkLinesListOption { default = [ ]; };
          postUpdate = mkLinesListOption { default = [ ]; };
        };
      };

      system = {
        allowUnfree = mkBoolOption { default = true; };
        arch = mkStrOption { default = "x86_64-linux"; };

        buildVm = {
          memory = mkNumberOption { default = 1024; };
          cores = mkNumberOption { default = 1; };
          diskSize = with types; mkEitherOption { default = "auto"; } str number;

          sharedDirectories = mkSubmoduleListOption { default = [ ]; } {
            source = mkStrOption { };
            target = mkStrOption { };
          };

          ssh = {
            enable = mkBoolOption { default = false; };
            hostPort = mkNumberOption { default = 2222; };
            vmPort = mkNumberOption { default = 22; };
          };

          resolution = mkStrOption { default = "1920x1080"; };
        };

        cache = {
          enable = mkBoolOption { default = true; };
          key = mkStrOption { default = readFile "${inputs.icedos-core.inputs.cache-server}/nix-public.pem"; };
          url = mkStrOption { default = "https://icedos.mirrors.knp.one"; };
        };

        channels = mkSubmoduleListOption { default = [ ]; } {
          name = mkStrOption { };
          url = mkStrOption { };
        }; # e.g. https://github.com/NixOS/nixpkgs/branches/active

        forceFirstBuild = mkBoolOption { default = false; };
        generations = mkNumberOption { default = 10; };
        isFirstBuild = mkBoolOption { default = false; };
        nixpkgsChannel = mkStrOption { default = "github:nixos/nixpkgs/nixos-unstable"; };
        packages = mkStrListOption { default = [ ]; };
        permittedInsecurePackages = mkStrListOption { default = [ ]; };

        # Pull selected packages from another channel/flake into the active pkgs
        # set as an overlay. Each entry must set either `channel` (an existing
        # `[[icedos.system.channels]]` name) or `url` (a flake URL — registered
        # automatically as `icedos-overlay-<sanitized-url>`); `channel` wins
        # when both are set. `packages` must be non-empty.
        overlays = {
          fromChannel = mkSubmoduleListOption { default = [ ]; } {
            channel = mkStrOption { default = ""; };
            packages = mkStrListOption { default = [ ]; };
            url = mkStrOption { default = ""; };
          };
        };

        version = mkStrOption { }; # Set according to docs at https://search.nixos.org/options?show=system.stateVersion
      };

      repositories = mkSubmoduleListOption { default = [ ]; } {
        url = mkStrOption { };
        overrideUrl = mkStrOption { default = ""; };
        fetchOptionalDependencies = mkBoolOption { default = false; };
        modules = mkStrListOption { default = [ ]; };
      };

      users = mkSubmoduleAttrsOption { } {
        defaultPassword = mkStrOption { default = "1"; };
        description = mkStrOption { default = ""; };
        extraGroups = mkStrListOption { default = [ ]; };
        home = mkStrOption { default = ""; };
        isNormalUser = mkBoolOption { default = true; };
        isSystemUser = mkBoolOption { default = false; };
        packages = mkStrListOption { default = [ ]; };
        sudo = mkBoolOption { default = true; };
      };
    };
  };

  config = import ../lib/load-user-config.nix "${inputs.icedos-config}";
}
