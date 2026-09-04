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
        # Shell snippet printing candidate values for a leaf command's positional
        # argument; empty = no dynamic completion.
        command = mkStrOption { default = ""; };
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

        cache = {
          days = mkNumberOption { default = 30; };
          generations = mkNumberOption { default = 100; };
        };

        hooks = {
          preGc = mkLinesListOption {
            default = [ ];
            description = ''
              Shell snippets run immediately before (`preGc`) garbage collection.
              Run once per normal user (see `icedos.users`), as that user — never
              as root by default: both `icedos gc` and the automatic
              `nh-clean.service` timer run them that way. The service is already
              root and switches per user with runuser; `icedos gc` elevates a
              single time with sudo and runs every per-user invocation inside that
              one root context. A hook may still escalate itself with `sudo` where
              the user it runs as has permission (e.g. NOPASSWD). Write hooks that
              make sense per user identity (e.g. sweeping ~/.cache) without
              assuming a specific user. Each invocation starts from a minimal
              environment (`env -i`) with only `HOME`, `USER`, `LOGNAME`, and a
              NixOS login `PATH` set — no XDG/DBus/invoker-PATH leakage.
            '';
          };

          postGc = mkLinesListOption {
            default = [ ];
            description = ''
              Shell snippets run immediately after (`postGc`) garbage collection.
              Run once per normal user (see `icedos.users`), as that user — never
              as root by default: both `icedos gc` and the automatic
              `nh-clean.service` timer run them that way. The service is already
              root and switches per user with runuser; `icedos gc` elevates a
              single time with sudo and runs every per-user invocation inside that
              one root context. A hook may still escalate itself with `sudo` where
              the user it runs as has permission (e.g. NOPASSWD). Write hooks that
              make sense per user identity (e.g. sweeping ~/.cache) without
              assuming a specific user. Each invocation starts from a minimal
              environment (`env -i`) with only `HOME`, `USER`, `LOGNAME`, and a
              NixOS login `PATH` set — no XDG/DBus/invoker-PATH leakage.
            '';
          };
        };
      };

      system.toolset = {
        commands = mkListOption { default = [ ]; } toolsetCommandType;
        configurationCommands = mkListOption { default = [ ]; } toolsetCommandType;
        desktopEntries = mkBoolOption { default = false; };
        sessionCommands = mkListOption { default = [ ]; } toolsetCommandType;

        rebuild.hooks = {
          preRebuild = mkLinesListOption {
            default = [ ];

            description = ''
              Shell snippets run before the build (`preRebuild`). Always run as
              the invoking user — the account running `icedos rebuild` — never
              escalated.
            '';
          };

          postRebuild = mkLinesListOption {
            default = [ ];

            description = ''
              Shell snippets run after activation (`postRebuild`). Always run as
              the invoking user — the account running `icedos rebuild` — never
              escalated.
            '';
          };

          preUpdate = mkLinesListOption {
            default = [ ];
            description = ''
              Shell snippets run before `--update` (and under `--update-hooks`).
              Always run as the invoking user — the account running
              `icedos rebuild` — never escalated.
            '';
          };

          postUpdate = mkLinesListOption {
            default = [ ];
            description = ''
              Shell snippets run after `--update` (and under `--update-hooks`).
              Always run as the invoking user — the account running
              `icedos rebuild` — never escalated.
            '';
          };
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

        build-vm = {
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
          enable = mkBoolOption { default = false; };
          url = mkStrOption { default = "https://icedos.fyi"; };

          key = mkStrOption {
            # `inputs.icedos-core` exists only at build stage, and forcing a missing
            # attr throws uncatchably — so guard the presence check.
            default =
              if inputs ? icedos-core then
                # Editors/publish steps may leave a trailing newline, which would
                # split the trusted-public-keys line in the generated nix.conf.
                lib.removeSuffix "\n" (
                  lib.trim (readFile "${inputs.icedos-core.inputs.cache-server}/nix-public.pem")
                )
              else
                "";
          };

          # Pin tracked leaf inputs to the revs cache-server last built (its
          # `tracked-inputs.json`), so rebuilds consume cached closures instead of
          # resolving fresh upstream revs. Needs one built cycle before it can pin.
          pinInputs = mkBoolOption { default = false; };

          priority = mkNumberOption { default = 100; };
        };

        channels = mkSubmoduleListOption { default = [ ]; } {
          name = mkStrOption { };
          url = mkStrOption { };
        }; # e.g. https://github.com/NixOS/nixpkgs/branches/active

        # Extra flake inputs under a user-chosen `name`, optionally loaded via
        # `modulesToLoad`. `name` must not collide with any other root input.
        extraFlakes = mkSubmoduleListOption { default = [ ]; } {
          name = mkStrOption { };
          url = mkStrOption { };
          inputs = mkAttrsOfOption { default = { }; } (types.attrsOf types.str);
          modulesToLoad = mkStrListOption { default = [ ]; };
        };

        # Scanned for modules (default.nix / icedos.nix, or loose *.nix). Read from
        # config.toml only (bootstrap path).
        extraModules = mkStrListOption { default = [ "modules" ]; };

        # Every *.toml (hidden .*.toml too) is merged onto config.toml. Read from
        # config.toml only (bootstrap path).
        extraConfigs = mkStrListOption { default = [ "configs" ]; };

        forceFirstBuild = mkBoolOption { default = false; };
        generations = mkNumberOption { default = 10; };

        git.users = mkSubmoduleAttrsOption { default = { }; } {
          username = mkStrOption { default = ""; };
          email = mkStrOption { default = ""; };
        };

        # Literal GitHub token passed to nix during rebuilds. WARNING: baked
        # into the nix store (world-readable) — prefer githubTokenPath.
        githubToken = mkStrOption { default = ""; };

        # File holding a GitHub token for nix github.com fetches during rebuilds;
        # per-run overrides: --github-token-path or ICEDOS_GITHUB_TOKEN_PATH.
        githubTokenPath = mkStrOption { default = icedosLib.GITHUB_TOKEN_PATH; };

        # Opt-in: emit `github:` input urls as `git+ssh://` so the ssh key (not
        # the token) authenticates fetches. Per-run override: --github-ssh.
        githubViaSsh = mkBoolOption { default = false; };

        # Framework-owned; baked by genflake (users get `forceFirstBuild`). No
        # default: readOnly rejects a second definition.
        isFirstBuild = mkBoolOption {
          internal = true;
          readOnly = true;
        };

        # Inline /etc/nixos/hardware-configuration.nix; the gate itself lives in
        # lib/genflake.nix, where the injection happens.
        loadHardwareConfiguration = mkBoolOption { default = true; };

        nixpkgsChannel = mkStrOption { default = "github:nixos/nixpkgs/nixos-unstable"; };
        packages = mkStrListOption { default = [ ]; };
        permittedInsecurePackages = mkStrListOption { default = [ ]; };

        # repo url -> loaded module names (enabled + transitive deps), injected
        # read-only from the raw config. Backs `icedosLib.hasModule`.
        loadedModules = mkAttrsOfOption {
          internal = true;
          # No `default`: it would count as a second definition, and a missed
          # injection must fail loud instead of silently reporting no modules.
          readOnly = true;
        } (types.listOf types.str);

        # Pull selected packages from another channel/flake in as an overlay. Each
        # entry sets `channel` or `url` (`channel` wins); `packages` must be non-empty.
        overlays = {
          fromChannel = mkSubmoduleListOption { default = [ ]; } {
            channel = mkStrOption { default = ""; };
            packages = mkStrListOption { default = [ ]; };
            url = mkStrOption { default = ""; };
          };
        };

        ssh = mkBoolOption { default = false; };

        sudo = {
          passwordFeedback = mkBoolOption {
            default = true;
            description = ''
              Show asterisks when typing the sudo password (`Defaults pwfeedback`).
              On by default for UX — blank input reads as a frozen tty — at the
              cost of disclosing password length to shoulder-surfers / tty
              readers. Set to false to harden.
            '';
          };
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
        # Patches applied to the whole repo source on top of its pinned rev.
        # Config-root-relative, so they reach the store.
        patches = mkStrListOption { default = [ ]; };

        # Patch a module's flake input from config, without forking the module.
        # Config-root-relative; applied after the author's own patches.
        inputPatches = mkSubmoduleListOption { default = [ ]; } {
          module = mkStrOption { };
          input = mkStrOption { };
          patches = mkStrListOption { default = [ ]; };
        };
      };

      users = mkSubmoduleAttrsOption { } {
        description = mkStrOption { default = ""; };
        extraGroups = mkStrListOption { default = [ ]; };
        home = mkStrOption { default = ""; };
        initialPassword = mkStrOption { default = "1"; };
        isNormalUser = mkBoolOption { default = true; };
        isSystemUser = mkBoolOption { default = false; };
        packages = mkStrListOption { default = [ ]; };
        sudo = mkBoolOption { default = true; };

        # Adds the user to `nix.settings.trusted-users`. Off by default: a trusted
        # user can tamper with the nix store.
        trusted = mkBoolOption { default = false; };
      };
    };
  };

  # One module per source file, so eval/type errors name the exact TOML file. The
  # strict cross-file key check still runs in load-user-config.nix.
  imports =
    let
      # The same pre-parsed set load-user-config.nix merges, so validation and the
      # raw passthrough never see a different list.
      configFiles = import ../lib/config/config-files.nix "${inputs.icedos-config}";
    in
    map (
      f:
      lib.setDefaultModuleLocation f.rel {
        config.icedos = f.content.icedos or { };
      }
    ) configFiles;
}
