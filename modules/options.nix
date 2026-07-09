{
  icedosLib,
  inputs,
  lib,
  ...
}:

let
  inherit (lib) readFile types;

  inherit (icedosLib)
    mkAttrsOfOption
    mkBoolOption
    mkEitherOption
    mkLinesListOption
    mkLinesOption
    mkListOption
    mkNonEmptyStrOption
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
      system.gc = {
        automatic = mkBoolOption { default = true; };
        days = mkNumberOption { default = 0; };
        generations = mkNumberOption { default = 10; };
        interval = mkStrOption { default = "Mon *-*-* 00:00:00"; };

        hooks = {
          preGc = mkLinesListOption { default = [ ]; };
          postGc = mkLinesListOption { default = [ ]; };
        };
      };

      system.toolset = {
        commands = mkListOption { default = [ ]; } toolsetCommandType;
        configurationCommands = mkListOption { default = [ ]; } toolsetCommandType;
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

        bootloaders = {
          grub = {
            enable = mkBoolOption { default = false; };
            device = mkStrOption { default = ""; };
          };

          systemd-boot = {
            enable = mkBoolOption { default = true; };
            mountPoint = mkNonEmptyStrOption { };
          };
        };

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
          url = mkStrOption { default = "https://icedos.mirrors.knp.one/icedos"; };

          key = mkStrOption {
            # `inputs.icedos-core` is only wired in at build stage; the genflake
            # stage imports this module with a minimal `inputs` (icedos-config
            # only). Guard the presence check — forcing the missing attr there
            # throws uncatchably (tryEval can't rescue it), which would abort any
            # full-config eval (`evaluatedConfig`, the search index, …).
            default =
              if inputs ? icedos-core then
                readFile "${inputs.icedos-core.inputs.cache-server}/nix-public.pem"
              else
                "";
          };

          priority = mkNumberOption { default = 100; };
        };

        channels = mkSubmoduleListOption { default = [ ]; } {
          name = mkStrOption { };
          url = mkStrOption { };
        }; # e.g. https://github.com/NixOS/nixpkgs/branches/active

        forceFirstBuild = mkBoolOption { default = false; };
        generations = mkNumberOption { default = 10; };

        git.users = mkSubmoduleAttrsOption { default = { }; } {
          username = mkStrOption { default = ""; };
          email = mkStrOption { default = ""; };
        };

        isFirstBuild = mkBoolOption { default = false; };

        # Inline /etc/nixos/hardware-configuration.nix into the system. On by
        # default so the machine's hardware essentials always apply; the gate
        # itself lives in lib/genflake.nix (injection happens at genflake stage).
        loadHardwareConfiguration = mkBoolOption { default = true; };

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

        ssh = mkBoolOption { default = false; };

        sudo = {
          passwordFeedback = mkBoolOption { default = true; };
          rs = mkBoolOption { default = true; };
        };

        version = mkStrOption { }; # Set according to docs at https://search.nixos.org/options?show=system.stateVersion

        zsh = {
          enable = mkBoolOption { default = true; };
          aliases = mkAttrsOfOption { default = { }; } types.str;
        };
      };

      repositories = mkSubmoduleListOption { default = [ ]; } {
        url = mkStrOption { };
        overrideUrl = mkStrOption { default = ""; };
        fetchDependencies = mkBoolOption { default = true; };
        fetchOptionalDependencies = mkBoolOption { default = false; };
        modules = mkStrListOption { default = [ ]; };
        # Patch files applied to the whole repo source on top of its pinned rev.
        # Paths are config-root-relative (they must live inside the config repo
        # so they reach the store). The repo analog of a module input's
        # `patches` (see `_getModuleInputs`).
        patches = mkStrListOption { default = [ ]; };

        # Consumer-declared input patches: patch a specific module's specific
        # flake input from config, without forking the module (the consumer
        # analog of a module author's `inputs.<input>.patches`). `patches` are
        # config-root-relative files; they apply after any author patches.
        inputPatches = mkSubmoduleListOption { default = [ ]; } {
          module = mkStrOption { };
          input = mkStrOption { };
          patches = mkStrListOption { default = [ ]; };
        };
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

        # Opt-in: add this user to `nix.settings.trusted-users` so they can
        # run unrestricted builds (e.g. shared build hosts, CI accounts).
        # Off by default — non-admin users should not be daemon-trusted, as
        # trusted-users can tamper the nix store. See
        # https://nix.dev/manual/nix/command-ref/conf-file#conf-trusted-users
        trusted = mkBoolOption { default = false; };
      };
    };
  };

  # Apply each source file as its own module so nixpkgs eval/type errors on
  # `icedos.*` values point back at the exact file (config.toml vs .private.toml)
  # instead of an anonymous `<unknown-file>`. The strict "same key in both files"
  # check still runs earlier in load-user-config.nix (used by genflake), so
  # splitting here loses no validation — it only sharpens error attribution.
  imports =
    let
      inherit (builtins) pathExists;

      icedosTable = file: (fromTOML (readFile file)).icedos or { };

      mainFile = "${inputs.icedos-config}/config.toml";
      privFile = "${inputs.icedos-config}/.private.toml";
    in
    [
      (lib.setDefaultModuleLocation "config.toml" {
        config.icedos = icedosTable mainFile;
      })
    ]
    ++ lib.optional (pathExists privFile) (
      lib.setDefaultModuleLocation ".private.toml" {
        config.icedos = icedosTable privFile;
      }
    );
}
