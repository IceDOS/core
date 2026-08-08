{
  icedosLib,
  lib,
  self,
  ...
}:

let
  inherit (builtins)
    attrNames
    fromJSON
    listToAttrs
    pathExists
    readFile
    replaceStrings
    seq
    ;

  inherit (icedosLib) generateAttrPath;

  inherit (builtins) foldl' stringLength;

  inherit (lib)
    concatMap
    concatMapStrings
    concatStrings
    concatStringsSep
    escapeShellArg
    fileContents
    filterAttrs
    flatten
    genList
    hasAttr
    hasAttrByPath
    hasSuffix
    mapAttrs
    mapAttrsToList
    max
    optional
    optionalString
    sort
    ;

  inherit (icedosLib)
    abortIf
    ICEDOS_STAGE
    ICEDOS_STATE_DIR
    INPUTS_PREFIX
    stringStartsWith
    ;

in
rec {
  # Lists module entry points under `path`: subdir paths whose dir contains
  # a `default.nix`, plus flat `.nix` files (excluding `default.nix`
  # itself). Preserves the input type — Nix-path stays path, string stays
  # string — so the result drops straight into `imports`.
  getModules =
    path:
    let
      entries = builtins.readDir path;
      isDir = _: v: v == "directory";
      isNixFile = n: v: v == "regular" && hasSuffix ".nix" n && n != "default.nix";
      dirs = attrNames (filterAttrs isDir entries);
      files = attrNames (filterAttrs isNixFile entries);
      dirHasDefault = dir: pathExists (path + "/${dir}/default.nix");
    in
    map (dir: path + "/${dir}") (builtins.filter dirHasDefault dirs)
    ++ map (file: path + "/${file}") files;

  # Whether an IceDOS module is part of this config. Replaces probing fake
  # option paths for recognition (e.g. `(config.icedos.desktop.kde.dynamic-workspaces or null) != null`).
  # Resolution order:
  #   - `url` given     -> check `loadedModules.${url}` contains every entry
  #     of `modules` (or `name`).
  #   - `repoUrl` given -> check `loadedModules.${repoUrl}` (the calling
  #     module's own repo, threaded through `_extractNixosModules`).
  #   - neither         -> scan every repo's loaded list for every entry.
  # A malformed call aborts: pass `name`, or a non-empty `modules` list — an
  # empty `modules = []` would make the membership check vacuously true.
  # DE detection: a DE repo is present iff it is configured, which is exactly
  # `hasModule { inherit config; url = "github:icedos/<de>"; modules = [ "default" ]; }`
  # — every DE repo always loads its `default` module when configured. The
  # DE-specific consumers of this pattern (session targets, accent resolution)
  # live in the desktop repo's repo-root `lib.nix` (contributed via that repo's
  # `default` module `lib` field); keep `hasModule` itself generic and
  # repo-agnostic.
  hasModule =
    {
      config,
      name ? null,
      url ? null,
      repoUrl ? null,
      modules ? null,
    }:
    let
      inherit (config.icedos.system) loadedModules;
      # A malformed call is a bug: `modules = []` makes `lib.all` vacuously
      # true (silently reporting the module "present"), and omitting BOTH
      # `name` and `modules` asks for nothing. `seq` forces the abort even when
      # `loadedModules == {}` would otherwise short-circuit the scan below.
      names =
        seq
          (abortIf (
            modules == [ ] || (name == null && modules == null)
          ) "hasModule: pass a module name or a non-empty modules list")
          (if modules != null then modules else [ name ]);
      inUrl = u: lib.all (n: lib.elem n (loadedModules.${u} or [ ])) names;
    in
    seq names (
      if url != null then
        inUrl url
      else if repoUrl != null then
        inUrl repoUrl
      else
        lib.any inUrl (builtins.attrNames loadedModules)
    );

  # Runtime bash helpers shared between Nix-embedded scripts (via the
  # auto-prepended `prelude` from toolset.nix:41) and standalone .sh files
  # (which `source` core/lib/prelude.sh directly). Both layers see the
  # same color vars, log_* / die / is_help_flag functions.
  bash = {
    prelude = builtins.readFile ./prelude.sh;

    # PATH export used by icedos systemd user services that shell out to
    # binaries from the host (e.g. systemctl, loginctl) and the user's
    # per-user system profile (`/etc/profiles/per-user/$USER`, where home-manager
    # installs packages under `useUserPackages`), in addition to whatever
    # derivation the unit ships. The legacy `~/.nix-profile/bin` is kept as a
    # harmless fallback (empty once `home.packages` move to the per-user profile).
    # Spliced into writeShellScript bodies via `${icedosLib.bash.exportSystemPath}`.
    exportSystemPath = ''
      base_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      nix_system_path="/run/current-system/sw/bin"
      nix_peruser_path="/etc/profiles/per-user/''${USER}/bin"
      nix_user_path="''${HOME}/.nix-profile/bin"
      export PATH="''${base_path}:''${nix_system_path}:''${nix_peruser_path}:''${nix_user_path}:$PATH"
    '';

    genHelpFlags =
      {
        excludeNoArgs ? false,
      }:
      let
        base = ''"$1" == "--help" || "$1" == "-h" || "$1" == "help" || "$1" == "h"'';
      in
      if excludeNoArgs then base else ''"$1" == "" || '' + base;

    # Generate a bash arg parser from a Nix flag spec. Returns bash source that
    # must be spliced into a script body (e.g. via `${icedosLib.bash.mkFlags {}}`).
    # Toolset leaves get the prelude auto-injected, so `die` is always available;
    # standalone consumers get a `die` polyfill at the top of the emitted block.
    mkFlags =
      {
        prefix,
        flags,
        passthroughUnknown ? false,
      }:
      let
        # Map flag name to bash variable name (e.g. "gpu-layers" → "LLAMACPP_GPU_LAYERS")
        toVarName = name: "${prefix}_${lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name)}";

        # Map flag name to "was set" tracking variable
        toSetVar = name: "${toVarName name}_SET";

        # Short flag pattern for case arm, e.g. "-H|" or ""
        shortPat = f: if f ? short then "-${f.short}|" else "";

        # Flag spec for help text alignment
        flagSpec =
          f:
          let
            shortPart = if f ? short then "-${f.short}, " else "    ";
            flagPart = "--${f.name}";
            typePart =
              if f.type == "string" then
                " <string>"
              else if f.type == "int" then
                " <int>"
              else if f.type == "bool" then
                ""
              else if f.type == "enum" then
                " <${lib.concatStringsSep "|" f.choices}>"
              else
                "";
          in
          "${shortPart}${flagPart}${typePart}";

        # Compute max flag spec width for alignment
        maxSpecLen = foldl' max 0 (map (f: stringLength (flagSpec f)) flags);

        # Help text line for one flag
        helpLine =
          f:
          let
            spec = flagSpec f;
            pad = maxSpecLen - stringLength spec + 2;
            defaultHelp =
              if f.type == "bool" then
                if f.default then "true" else "false"
              else if f.type == "int" then
                toString (builtins.floor f.default)
              else
                toString f.default;
          in
          "  ${spec}${
              lib.concatStringsSep "" (lib.genList (_: " ") pad)
            }${f.description} (default: ${defaultHelp})";

        # Full help text with real newlines
        helpText = "Flags:\n${lib.concatStringsSep "\n" (map helpLine flags)}";

        # Escaped default value for bash
        escDefault =
          f:
          if f.type == "bool" then
            if f.default then "true" else "false"
          else if f.type == "int" then
            lib.escapeShellArg (toString (builtins.floor f.default))
          else
            lib.escapeShellArg (toString f.default);

        # Variable declarations for one flag
        varDecl = f: "${toVarName f.name}=${escDefault f}\n${toSetVar f.name}=0";

        # Generate case arms for one flag
        genCaseArm =
          f:
          let
            var = toVarName f.name;
            svar = toSetVar f.name;
            long = "--${f.name}";
            sp = shortPat f;
          in
          if f.type == "bool" then
            ''
              ${sp}${long})
                ${var}="true"; ${svar}=1
                shift
                ;;
              --no-${f.name})
                ${var}="false"; ${svar}=1
                shift
                ;;
              ${long}=true|${long}=false)
                ${var}="''${1#${long}=}"; ${svar}=1
                shift
                ;;
            ''
          else
            ''
              ${sp}${long})
                [[ $# -ge 2 ]] || die "${long} requires a value"
                ${lib.optionalString (
                  f.type == "int"
                ) ''[[ "$2" =~ ^-?[0-9]+$ ]] || die "${long} must be an integer"''}
                ${lib.optionalString (f.type == "enum") ''
                  case "$2" in
                    ${lib.concatStringsSep "|" f.choices}) ;;
                    *) die "invalid value for ${long}: $2 (choose: ${lib.concatStringsSep ", " f.choices})" ;;
                  esac
                ''}
                ${var}="$2"; ${svar}=1
                shift 2
                ;;
              ${long}=*)
                v="''${1#${long}=}"
                ${lib.optionalString (
                  f.type == "int"
                ) ''[[ "$v" =~ ^-?[0-9]+$ ]] || die "${long} must be an integer"''}
                ${lib.optionalString (f.type == "enum") ''
                  case "$v" in
                    ${lib.concatStringsSep "|" f.choices}) ;;
                    *) die "invalid value for ${long}: $v (choose: ${lib.concatStringsSep ", " f.choices})" ;;
                  esac
                ''}
                ${var}="$v"; ${svar}=1
                shift
                ;;
            '';

        shorts = lib.filter (s: s != null) (map (f: if f ? short then f.short else null) flags);
      in
      assert lib.assertMsg (lib.all (n: builtins.match "^[a-z0-9-]+$" n != null) (
        map (f: f.name) flags
      )) "mkFlags (${prefix}): flag names must match [a-z0-9-]+";
      assert lib.assertMsg (lib.all (
        s: builtins.match "^[a-zA-Z0-9-]+$" s != null
      ) shorts) "mkFlags (${prefix}): short flags must match [a-zA-Z0-9-]+";
      assert lib.assertMsg (
        lib.length (lib.unique (map (f: toVarName f.name) flags)) == lib.length flags
      ) "mkFlags (${prefix}): duplicate variable names generated";
      assert lib.assertMsg (
        lib.length (lib.unique shorts) == lib.length shorts
      ) "mkFlags (${prefix}): duplicate short flags";
      assert lib.assertMsg (
        !(lib.elem "help" (map (f: f.name) flags))
      ) "mkFlags (${prefix}): 'help' is a reserved flag name";
      assert lib.assertMsg (!(lib.elem "h" shorts)) "mkFlags (${prefix}): 'h' is a reserved short flag";
      ''
                if ! declare -F die >/dev/null 2>&1; then
                  die() { printf 'error: %s\n' "$*" >&2; exit 1; }
                fi

                ${lib.concatStringsSep "\n" (map varDecl flags)}

                _HELP_TEXT=$(cat <<'__ICEDOS_MKFLAGS_EOF__'
        ${helpText}
        __ICEDOS_MKFLAGS_EOF__
                )

                _REST=()
                while [[ $# -gt 0 ]]; do
                  case "$1" in
                    -h|--help)
                      echo "$_HELP_TEXT"
                      exit 0
                      ;;
                    ${lib.concatStringsSep "\n" (map genCaseArm flags)}
                    --)
                      shift
                      _REST+=("$@")
                      break
                      ;;
                    ${
                      if passthroughUnknown then
                        ''
                          -*)
                            _REST+=("$1")
                            shift
                            ;;
                        ''
                      else
                        ''
                          -*)
                            die "unknown flag: $1"
                            ;;
                        ''
                    }
                    *)
                      _REST+=("$1")
                      shift
                      ;;
                  esac
                done
                set -- "''${_REST[@]}"
      '';

    blueString = s: "\${BLUE}${s}\${NC}";
    greenString = s: "\${GREEN}${s}\${NC}";
    purpleString = s: "\${PURPLE}${s}\${NC}";
    redString = s: "\${RED}${s}\${NC}";
    yellowString = s: "\${YELLOW}${s}\${NC}";

    dimBlueString = s: "\${DIM_BLUE}${s}\${NC}";
    dimGreenString = s: "\${DIM_GREEN}${s}\${NC}";
    dimPurpleString = s: "\${DIM_PURPLE}${s}\${NC}";
    dimRedString = s: "\${DIM_RED}${s}\${NC}";
    dimYellowString = s: "\${DIM_YELLOW}${s}\${NC}";

    # Config-set paths + the shell walker shared by the `icedos configuration`
    # diff / rollback / history commands: all three pair a snapshot folder
    # (`.cache/<timestamp>/`, written by rebuild.nix's snapshot_config_set)
    # against the working tree, over the same file set — config.toml plus every
    # *.toml, hidden .*.toml included, under each `icedos.system.extraConfigs`
    # dir. Takes the NixOS `config`.
    configSet =
      config:
      let
        inherit (config.icedos) configurationLocation;
        configRoot = "${configurationLocation}/..";
        workingConfig = "${configRoot}/config.toml";
        configDirsArgs = concatStringsSep " " (map escapeShellArg config.icedos.system.extraConfigs);
      in
      {
        inherit configRoot workingConfig configDirsArgs;
        cacheDir = "${configurationLocation}/.cache";

        # Defines CONFIG_DIRS + `walk_config_set <snapshot_root> <fn>`, which
        # calls `<fn> <label> <snapshot_path> <working_path>` once per file in
        # the union of both sides — so files added or removed since the snapshot
        # are visible too (the callback maps a missing side to /dev/null).
        # A trailing slash on <snapshot_root> is accepted. The callback runs in
        # the caller's shell (here-string, not a pipe), so it can set variables.
        walk = ''
          CONFIG_DIRS=(${configDirsArgs})

          walk_config_set() {
            local root="''${1%/}" fn="$2" d b names f
            "$fn" "config.toml" "$root/config.toml" "${workingConfig}"
            shopt -s nullglob
            for d in "''${CONFIG_DIRS[@]}"; do
              names="$(
                for f in "$root/$d/"*.toml "$root/$d/".*.toml \
                         "${configRoot}/$d/"*.toml "${configRoot}/$d/".*.toml; do
                  basename "$f"
                done | sort -u
              )"
              while IFS= read -r b; do
                [ -n "$b" ] || continue
                "$fn" "$d/$b" "$root/$d/$b" "${configRoot}/$d/$b"
              done <<< "$names"
            done
            shopt -u nullglob
          }
        '';
      };

    # Timer-value acquisition for nh-clean timer. Sets gc_age/gc_dt when a
    # trigger timestamp is available; leaves them empty otherwise. Callers
    # set `now` then format the output. Sourced from the systemd timer's
    # LastTriggerUSec which persists across reboots (Persistent flag on the
    # timer unit).
    gcTimerCheckSnippet = { systemctl }: ''
      last=$(${systemctl} show nh-clean.timer -p LastTriggerUSec --value --timestamp=unix 2>/dev/null)
      ts="''${last#@}"
      if [ -n "$ts" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
        gc_age=$(((now - ts) / 86400))
        gc_dt=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")
      else
        gc_age=""
        gc_dt=""
      fi
    '';

    # Guard before executing anything from the baked `configurationLocation`.
    # It can point into another user's home (default `$PWD/.state` of whoever
    # ran the first build), and running its `build.sh` lets that owner execute
    # code as the invoker (and as root during a switch). This is a
    # permission check, not an ownership check:
    #
    #   - the invoker can read+execute the config (and its .state dir) →
    #     if another user's, warn one line that their build.sh will run as
    #     the invoker, then proceed; if the invoker's own, proceed silently —
    #     they're authorized to run it
    #   - same owner but NOT readable → warn to fix the permissions, proceed
    #     (the build will fail on its own if truly broken)
    #   - different owner, not readable, invoker not root → warn and prompt;
    #     on y/Y re-run the command as the owner (`sudo -u`, re-entry guarded
    #     by `ICEDOS_OWNER_RERUN=1`), on anything else fall through so the
    #     caller's own checks (e.g. rebuild's "use current directory?"
    #     bootstrap) decide, with `ICEDOS_OWNER_DECLINED=1` set so those callers
    #     can tell EACCES from a missing config.
    #   - different owner and the invoker is root → prompt regardless of
    #     readability (`test -r`/`-x` always pass for uid 0), so root never
    #     silently executes another user's build.sh. Accept re-runs as the
    #     owner via `runuser` + `env -i` (owner HOME/PATH, mirroring nh.nix);
    #     declining aborts — root passes every `-d` test, so no caller
    #     fall-through could stop the build.
    #   - non-interactive (stdin not a tty): an unreadable root aborts
    #     unconditionally; a root invoker on an accessible root has been warned
    #     and proceeds (so scripted/CI rebuilds that elevate don't hard-fail).
    #   - a failed re-run keeps the re-run's exit status.
    #
    # Call with the config root (`"${configurationLocation}/.."`), the config's
    # state dir (that's `"${configurationLocation}"` — it IS the state dir; see
    # `options.icedos.configurationLocation` in lib/genflake.nix), and the
    # command's ORIGINAL args (capture `ORIG_ARGS=("$@")` at the top of the
    # script, before any parsing shifts them), so the owner re-run gets the same
    # command line. Safe to call only when `$0` resolves to the command script.
    requireConfigOwner = ''
      require_config_owner() {
        local root="$1" state_dir="$2" orig="$1" owner me state answer rc PROMPT readable probe warn_suffix owner_home owner_path
        shift 2
        # `test -d` cannot tell "absent" from "inaccessible": a 0700 parent
        # (the NixOS homeMode default) makes it fail with EACCES, silently
        # skipping a config root that lives in another user's home. Probe
        # with stat and only treat the root as absent when it really is
        # (ENOENT).
        root=$(realpath -m "$root" 2>/dev/null) || root="$orig"
        warn_suffix=""
        if ! owner=$(LC_ALL=C stat -c %U "$root" 2>&1); then
          case "$owner" in
            *'No such file or directory'* | *'Not a directory'* | *'not a directory'*)
              return 0
              ;;
          esac
          # Inaccessible — walk up to the first stat-able ancestor to find
          # who owns the tree this command would execute.
          owner=""
          probe="$root"
          while [ -n "$probe" ] && [ "$probe" != "/" ]; do
            if owner=$(stat -c %U "$probe" 2>/dev/null); then
              break
            fi
            case "$probe" in
              */*) probe="''${probe%/*}" ;;
              *) break ;;
            esac
          done
          [ -n "$owner" ] || return 0
          warn_suffix=" (nearest accessible ancestor)"
        fi
        me=$(id -un)
        state="''${state_dir:-$root/.state}"

        # Re-entered after an owner re-run — never prompt again, or unrelated
        # sudo hops could ping-pong between users.
        if [ -n "''${ICEDOS_OWNER_RERUN:-}" ]; then
          return 0
        fi

        if [ -r "$root" ] && [ -x "$root" ] \
           && { [ ! -e "$state" ] || { [ -r "$state" ] && [ -x "$state" ]; }; }; then
          readable=1
        else
          readable=0
        fi

        if [ "$owner" != "$me" ]; then
          # Another user's config root — warn whoever runs it, even when
          # readable, so they know whose build.sh executes as them.
          echo -e "''${YELLOW}warning''${NC}: configuration root '$root' is owned by '$owner'$warn_suffix; running it as '$me'." >&2
          # Prompt for a re-run when the root isn't readable, or whenever the
          # invoker is root: `test -r`/`-x` always succeed for uid 0, so
          # readability alone would let root silently execute another user's
          # build.sh. The runuser branch below is the only root-side re-run
          # path, so it must be reachable.
          if [ "$readable" = "0" ] || [ "$(id -u)" -eq 0 ]; then
            echo "         Re-running as '$owner' executes that user's build.sh with '$me' privileges." >&2
            if [ -t 0 ]; then
              printf -v PROMPT '%b' "''${DIM_GREEN}>''${NC} Run 'icedos' as '$owner'? [y/N] "
              read -r -p "$PROMPT" answer
              case "$answer" in
                [yY]|[yY][eE][sS]) ;;
                # Declined. A root invoker must abort outright: uid 0 passes
                # every `-d`/`-r`/`-x` test, so there is no fall-through that
                # would stop the build — proceeding would execute the other
                # user's build.sh as root anyway. A non-root invoker falls
                # through so the caller's own checks (e.g. rebuild's "use
                # current directory?" bootstrap) get a say, with the flag set
                # so those callers can tell EACCES from a missing config.
                *)
                  if [ "$(id -u)" -eq 0 ]; then
                    die "aborted: declined to execute the configuration root of '$owner' as root"
                  fi
                  ICEDOS_OWNER_DECLINED=1
                  return 0
                  ;;
              esac
            else
              # Unattended (stdin not a tty): an unreadable root can't be
              # recovered from — abort. A root invoker on an accessible root
              # has already been warned above; let it proceed, or scripted/
              # CI rebuilds that legitimately elevate would hard-fail.
              [ "$readable" = "0" ] && die "aborted: no permission to configuration root '$root' (owned by '$owner')"
              return 0
            fi

            if [ "$(id -u)" -eq 0 ]; then
              # `runuser` inherits root's env (HOME=/root, root's PATH, …) by
              # default, which breaks the owner's nix — mirror nh.nix and pin
              # the identity plus a NixOS login PATH via `env -i`, resolving
              # the owner's home at runtime.
              owner_home=$(getent passwd "$owner" | cut -d: -f6)
              [ -n "$owner_home" ] || owner_home="/home/$owner"
              owner_path="/run/wrappers/bin:$owner_home/.nix-profile/bin:$owner_home/.local/state/nix/profile/bin:/etc/profiles/per-user/$owner/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin"
              /run/current-system/sw/bin/runuser -u "$owner" -- \
                /run/current-system/sw/bin/env -i "HOME=$owner_home" "USER=$owner" "LOGNAME=$owner" "PATH=$owner_path" \
                ICEDOS_OWNER_RERUN=1 "$0" "$@"
            else
              # sudo resets the environment by default, so carry the re-entry
              # marker explicitly rather than as a bare `VAR=x sudo …` prefix.
              # Resolve sudo by the setuid wrapper path (the only working one).
              /run/wrappers/bin/sudo -u "$owner" -- /run/current-system/sw/bin/env ICEDOS_OWNER_RERUN=1 "$0" "$@"
            fi
            rc=$?
            [ "$rc" -eq 0 ] && exit 0
            echo "re-run as '$owner' exited with $rc" >&2
            exit "$rc"
          fi
          return 0
        fi

        # Same owner, but the config isn't readable — they'll likely hit a
        # confusing build failure, so point at the permissions up front.
        if [ "$readable" = "0" ]; then
          echo -e "''${YELLOW}warning''${NC}: you do not have read/execute permission on configuration root '$root'." >&2
          echo "         Fix the permissions before running 'icedos rebuild' — the build will fail otherwise." >&2
        fi
        return 0
      }
    '';
  };

  # icedos toolset framework: the dispatcher generator (used to build
  # `icedos` itself and every subcommand attrset that has children) and
  # the per-shell completion generators. `walkBranches` and
  # `walkFileLeaves` are private helpers consumed only by the three
  # completion generators.
  toolset =
    let
      # Walks the command tree and yields one record per branch node (a
      # node with at least one child), describing which children are
      # valid completions at that point in the command line.
      walkBranches =
        commands:
        let
          go =
            parentPath: cmds:
            if cmds == [ ] then
              [ ]
            else
              [
                {
                  path = parentPath;
                  children = sort (a: b: a.name < b.name) (
                    map (c: {
                      name = c.command;
                      help = c.help;
                    }) cmds
                  );
                }
              ]
              ++ concatMap (c: go (parentPath ++ [ c.command ]) c.commands) cmds;
        in
        go [ ] commands;

      # Walks the command tree and yields one record per leaf node (a
      # node with no children) that has opted into argument completion
      # via `completion.files = true`.
      walkFileLeaves =
        commands:
        let
          go =
            parentPath: cmds:
            concatMap (
              c:
              let
                myPath = parentPath ++ [ c.command ];
                isFileLeaf = c.commands == [ ] && (c.completion.files or false);
              in
              (if isFileLeaf then [ { path = myPath; } ] else [ ]) ++ go myPath c.commands
            ) cmds;
        in
        go [ ] commands;

      # Walks the command tree and yields one record per leaf node that
      # opted into dynamic argument completion via a non-empty
      # `completion.command` (a shell snippet printing newline-separated
      # candidate values). Each record carries the leaf path and the snippet.
      walkValueLeaves =
        commands:
        let
          go =
            parentPath: cmds:
            concatMap (
              c:
              let
                myPath = parentPath ++ [ c.command ];
                isValueLeaf = c.commands == [ ] && (c.completion.command or "") != "";
              in
              (
                if isValueLeaf then
                  [
                    {
                      path = myPath;
                      cmd = c.completion.command;
                    }
                  ]
                else
                  [ ]
              )
              ++ go myPath c.commands
            ) cmds;
        in
        go [ ] commands;
    in
    {
      mkDispatcher =
        { commands }:
        let
          sorted = sort (a: b: a.command < b.command) commands;
          maxLen = foldl' max 0 (map (c: stringLength c.command) sorted);
          pad = s: s + concatStrings (genList (_: " ") (maxLen - stringLength s));

          # Aligns help text to a single column across the whole tree by
          # padding each command to `globalCmdWidth - (depth * 2)`, so the
          # 2-char-per-level indent eats exactly the padding shrinkage.
          # Without this, each subtree padded to its own siblings' max,
          # making deep rows' help text drift left of shallow rows'.
          renderTree =
            let
              walk =
                depth: cmds:
                concatMap (c: [ (depth * 2 + stringLength c.command) ] ++ walk (depth + 1) c.commands) cmds;
              globalCmdWidth = foldl' max 0 (walk 0 sorted);

              go =
                depth: cmds:
                let
                  sortedAtDepth = sort (a: b: a.command < b.command) cmds;
                  padTarget = globalCmdWidth - (depth * 2);
                  padAtDepth = s: s + concatStrings (genList (_: " ") (padTarget - stringLength s));
                  indent = concatStrings (genList (_: "  ") depth);
                in
                concatMapStrings (
                  c:
                  ''
                    echo -e "${indent}> ${purpleString (padAtDepth c.command)}    ${c.help}"
                  ''
                  + (if c.commands != [ ] then go (depth + 1) c.commands else "")
                ) sortedAtDepth;
            in
            go;

          inherit (bash)
            prelude
            genHelpFlags
            purpleString
            redString
            ;
        in
        ''
          ${prelude}

          if [[ "$1" == "--tree" ]]; then
            echo "Available commands:"

            ${renderTree 0 sorted}

            exit 0
          fi

          if [[ ${genHelpFlags { }} ]]; then
            echo "Available commands:"

            ${concatMapStrings (c: ''
              echo -e "> ${purpleString (pad c.command)}    ${c.help}"
            '') sorted}

            exit 0
          fi

          case "$1" in
            ${concatMapStrings (c: ''
              ${c.command})
                shift
                exec ${c.bin} "$@"
                ;;
            '') commands}
            *|-*|--*)
              echo -e "${redString "Unknown arg"}: $1" >&2
              exit 1
              ;;
          esac
        '';

      mkBashCompletion =
        { commands }:
        let
          branches = walkBranches commands;
          fileLeaves = walkFileLeaves commands;
          valueLeaves = walkValueLeaves commands;
          childNames = b: concatStringsSep " " (map (c: c.name) b.children);
          branchArm = b: ''
            ${escapeShellArg (concatStringsSep " " b.path)})
                words=${escapeShellArg (childNames b)}
                ;;
          '';
          # Leaf paths match both the exact path (cursor at first arg) and
          # `<path> *` (cursor at any later arg) so file completion fires
          # for every positional argument the leaf accepts.
          fileLeafArm =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            ''
              ${escapeShellArg p} | ${escapeShellArg "${p} "}*)
                  if declare -F _filedir >/dev/null 2>&1; then
                      _filedir
                  else
                      COMPREPLY=( $(compgen -f -- "$cur") )
                  fi
                  return
                  ;;
            '';
          # Value-completing leaves run their snippet and offer its
          # newline-separated output as candidates for any positional arg.
          # IFS is reset to newline here because the function body sets
          # `IFS=' '` for the key join, which would mis-split the candidates.
          valueLeafArm =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            ''
              ${escapeShellArg p} | ${escapeShellArg "${p} "}*)
                  local IFS=$'\n'
                  COMPREPLY=( $(compgen -W "$(${l.cmd})" -- "$cur") )
                  return
                  ;;
            '';
        in
        ''
          _icedos() {
              local cur="''${COMP_WORDS[COMP_CWORD]}"
              local -a _icedos_args=("''${COMP_WORDS[@]:1:$((COMP_CWORD - 1))}")
              local IFS=' '
              local key="''${_icedos_args[*]}"
              local words=""
              case "$key" in
          ${concatMapStrings (l: "      " + valueLeafArm l) valueLeaves}${
            concatMapStrings (l: "      " + fileLeafArm l) fileLeaves
          }${concatMapStrings (b: "      " + branchArm b) branches}      esac
              COMPREPLY=( $(compgen -W "$words" -- "$cur") )
          }
          complete -F _icedos icedos
        '';

      mkZshCompletion =
        { commands }:
        let
          branches = walkBranches commands;
          fileLeaves = walkFileLeaves commands;
          valueLeaves = walkValueLeaves commands;
          # Escape colons (zsh _describe's name/help delimiter) with a backslash.
          escColons = replaceStrings [ ":" ] [ "\\:" ];
          entryStr = c: escapeShellArg "${c.name}:${escColons c.help}";
          branchArm = b: ''
              ${escapeShellArg (concatStringsSep " " b.path)})
                  entries=(
            ${concatMapStrings (c: "          " + entryStr c + "\n") b.children}          )
                  ;;
          '';
          fileLeafArm =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            ''
              ${escapeShellArg p} | ${escapeShellArg "${p} "}*)
                  _files
                  return
                  ;;
            '';
          # Value-completing leaves: run the snippet, split its output on
          # newlines (the `f` flag), and offer the lines via compadd.
          valueLeafArm =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            ''
              ${escapeShellArg p} | ${escapeShellArg "${p} "}*)
                  local -a vals
                  vals=("''${(@f)$(${l.cmd})}")
                  compadd -a vals
                  return
                  ;;
            '';
        in
        ''
          #compdef icedos
          _icedos() {
              local -a _icedos_path entries
              local key
              _icedos_path=("''${(@)words[2,$((CURRENT - 1))]}")
              key="''${(j: :)_icedos_path}"
              entries=()
              case "$key" in
          ${concatMapStrings (l: "      " + valueLeafArm l) valueLeaves}${
            concatMapStrings (l: "      " + fileLeafArm l) fileLeaves
          }${concatMapStrings (b: "      " + branchArm b) branches}      esac
              if (( ''${#entries} > 0 )); then
                  _describe -t commands 'icedos command' entries
              fi
          }
          _icedos "$@"
        '';

      mkFishCompletion =
        { commands }:
        let
          branches = walkBranches commands;
          fileLeaves = walkFileLeaves commands;
          valueLeaves = walkValueLeaves commands;
          line = c: "        printf '%s\\t%s\\n' ${escapeShellArg c.name} ${escapeShellArg c.help}\n";

          caseArm = b: ''
              case ${escapeShellArg (concatStringsSep " " b.path)}
            ${concatMapStrings line b.children}'';

          # Each file-completing leaf gets its own `complete -F` line gated
          # on the current argv prefix matching the leaf's path. `-F`
          # forces file completion and overrides the global `-f` only when
          # the predicate matches, so branch nodes still get subcommand
          # names instead of files.
          fileLeafComplete =
            l:
            let
              p = concatStringsSep " " l.path;
            in
            "complete -c icedos -F -n ${escapeShellArg ''__icedos_path_match "${p}"''}\n";

          # fish can't inline a quoted command as a `complete -a` argument,
          # so each value leaf gets a wrapper function running its snippet;
          # the completion offers that function's newline-separated output.
          fnName = l: "__icedos_vals_" + replaceStrings [ " " ] [ "_" ] (concatStringsSep " " l.path);
          valueLeafFn = l: ''
            function ${fnName l}
                ${l.cmd}
            end
          '';
          valueLeafComplete =
            l:
            "complete -c icedos -f -n ${escapeShellArg ''__icedos_path_match "${concatStringsSep " " l.path}"''} -a ${escapeShellArg "(${fnName l})"}\n";
        in
        ''
          function __icedos_complete_path
              set -l tokens (commandline -opc)
              set -e tokens[1]
              if set -q tokens[1]
                  string join ' ' -- $tokens
              end
          end

          function __icedos_path_match
              set -l p (__icedos_complete_path)
              test "$p" = "$argv[1]"; and return 0
              string match -q -- "$argv[1] *" "$p"
          end

          function __icedos_complete
              set -l p (__icedos_complete_path)
              switch "$p"
          ${concatMapStrings (b: "        " + caseArm b) branches}    end
          end

          ${concatMapStrings valueLeafFn valueLeaves}complete -c icedos -f -a '(__icedos_complete)'
          ${concatMapStrings fileLeafComplete fileLeaves}${concatMapStrings valueLeafComplete valueLeaves}'';
    };

  # Authoritative libadwaita named-accent → hex map and the
  # `icedos.desktop.accentColor` resolver (`generateAccent`), plus the
  # `desktop`/`systemd` namespaces built on them, moved to the desktop repo's
  # repo-root `lib.nix` (see desktop/lib.nix), contributed via that repo's
  # `default` module `lib` field. They are DE-dependent, so they
  # belong with the DEs, not in core.
  users = {
    getNormal =
      { users }:
      mapAttrsToList (name: attrs: {
        inherit name;
        value = attrs;
      }) (filterAttrs (n: v: v.isNormalUser) users);

    # Per-normal-user attrset for `users` submodule options. Lets modules avoid
    # forcing the user to write `[icedos.<path>.users.<name>]` per system user
    # just to materialise the option's submodule defaults.
    genDefaults =
      {
        users,
        value ? { },
      }:
      mapAttrs (_: _: value) (filterAttrs (_: v: v.isNormalUser) users);

    mkGroupInjector = group: users: mapAttrs (_: _: { extraGroups = [ group ]; }) users;
  };

  color = {
    hexToRgbInts =
      hex:
      let
        inherit (lib) fromHexString removePrefix;
        inherit (builtins) substring;
        h = removePrefix "#" hex;
      in
      [
        (fromHexString (substring 0 2 h))
        (fromHexString (substring 2 2 h))
        (fromHexString (substring 4 2 h))
      ];
  };

  pkgs = rec {
    mapper = pkgs: pkgList: map (pkgName: generateAttrPath pkgs pkgName) pkgList;

    # Single source of truth for the nixpkgs `config` attrset. Every
    # consumer (genflake codegen, runtime `nixpkgs.config`,
    # `overlaysFromChannel`) routes through this so the keys we forward
    # never drift. Hardware-driven keys (`cudaSupport`, `rocmSupport`)
    # come from per-key writes in hardware modules and merge in via
    # Nix's attrset-option merging — they intentionally don't live here.
    mkConfig = icedos: {
      inherit (icedos.system)
        allowUnfree
        permittedInsecurePackages
        ;
    };

    # Build an overlay that lifts named packages from a channel source into
    # the active pkgs set. The source can be:
    #   - a channel-name string (e.g. `"unstable"`) — looked up on `super`,
    #     which assumes the channel is already wired via
    #     `nixpkgs.config.packageOverrides.<name>` (icedos's
    #     `[[icedos.system.channels]]` does this automatically);
    #   - a flake-input attrset (e.g. `inputs.nixpkgs-stable`) detected by
    #     the presence of `outPath` — instantiated against the host's
    #     `system` with `mkConfig icedos` forwarded. The full host
    #     `nixpkgs.config` is NOT propagated: post-overlay it carries
    #     internal nulls (e.g. `replaceStdenv`) that crash a fresh
    #     instantiation. Source overlays are also intentionally NOT
    #     forwarded.
    # Returns a single-item overlay list ready to drop into
    # `nixpkgs.overlays`.
    overlaysFromChannel = icedos: channel: packages: [
      (
        self: super:
        let
          channelPkgs =
            if channel ? outPath then
              import channel {
                inherit (super.stdenv.hostPlatform) system;
                config = mkConfig icedos;
              }
            else
              super.${channel};
        in
        listToAttrs (
          map (package: {
            name = package;
            value = generateAttrPath channelPkgs package;
          }) packages
        )
      )
    ];
  };

  # Shell-snippet builders for `installPhase` / `postFixup` bodies in
  # icedos `package.nix` files. Centralizes conventions (the `/@out@`
  # marker for `makeDesktopItem`, the AppImage extract dance) so a fix
  # in one place propagates to every packaged AppImage. Reached by
  # `package.nix` files only via explicit pass-through in the module's
  # `icedos.nix`: `final.callPackage ./package.nix { inherit
  # (icedosLib.packaging) extractAppImage installDesktopEntry; };`.
  packaging = {
    # Stages an AppImage in $TMPDIR, extracts it, and merges the
    # contents into $out. `extractedDir` is whatever the AppImage
    # extracts to ("AppDir" — citron/eden style; "squashfs-root" — me3
    # style). `moveSubdir` lets callers merge a nested dir like "usr"
    # into $out instead of the whole tree. `steamRun` (optional pkg)
    # prefixes the extract invocation for AppImages that need a glibc
    # envelope. `preMove` is raw shell that runs after extract and
    # before the mv (e.g. `rm AppDir/lib`).
    extractAppImage =
      {
        src,
        extractedDir ? "AppDir",
        moveSubdir ? null,
        steamRun ? null,
        preMove ? "",
      }:
      ''
        mkdir -p $out
        cp ${src} $TMPDIR/image.AppImage
        chmod +x $TMPDIR/image.AppImage
        ${
          optionalString (steamRun != null) "${steamRun}/bin/steam-run "
        }$TMPDIR/image.AppImage --appimage-extract
        ${preMove}
        mv ${extractedDir}/${optionalString (moveSubdir != null) "${moveSubdir}/"}* $out
      '';

    # Standard desktop-entry install + @out@ substitution + optional
    # icon symlink. Works in installPhase or postFixup. `desktopItem`
    # is a `makeDesktopItem` result whose `exec`/`icon` use the
    # `${replaceMarker}` placeholder (default `/@out@`) so the file can
    # be substituted in-place to the real $out at install time.
    installDesktopEntry =
      {
        desktopItem,
        desktopFile,
        icon ? null,
        replaceMarker ? "/@out@",
      }:
      ''
        install -Dm644 ${desktopItem}/share/applications/${desktopFile} \
          $out/share/applications/${desktopFile}
        substituteInPlace $out/share/applications/${desktopFile} \
          --replace-fail "${replaceMarker}" "$out"
      ''
      + optionalString (icon != null) ''
        ln -s $out/${icon} $out/share/applications/${icon}
      '';
  };

  injectIfExists =
    { file }:
    if (pathExists file) then
      ''
        (
          ${fileContents file}
        )
      ''
    else
      "";

  scanModules =
    {
      path,
      filename,
      maxDepth ? -1,
    }:
    let
      inherit (builtins) readDir;

      getContentsByType = fileType: filterAttrs (name: type: type == fileType) contents;

      targetPath = if (stringStartsWith "/nix/store" "${path}") then "${path}" else "${self}/${path}";
      contents = readDir targetPath;

      directories = getContentsByType "directory";
      files = getContentsByType "regular";

      directoriesPaths = map (n: "${path}/${n}") (attrNames directories);

      icedosFiles = filterAttrs (n: v: n == filename) files;
      icedosFilesPaths = map (n: "${targetPath}/${n}") (attrNames icedosFiles);
    in
    icedosFilesPaths
    ++ optional (maxDepth != 0) (
      flatten (
        map (
          dp:
          scanModules {
            inherit filename;
            path = dp;
            maxDepth = maxDepth - 1;
          }
        ) directoriesPaths
      )
    );

  # ─── flake / input helpers ────────────────────────────────────────────────
  # Consumed by lib/genflake.nix and lib/icedos.nix.

  # Build a flake-input name from arbitrary identifying parts. Joins with
  # `-`, prefixes with `INPUTS_PREFIX`, and replaces flake-URL-unsafe
  # characters (`:`, `/`, `.`, `?`, `=`) with `_` so the result is a valid
  # flake registry name. Used for module submodule inputs (parts: [ url ] or
  # [ url subMod ]) and for url-mode overlay inputs (parts: [ "overlay" url ]).
  mkInputName =
    { parts }:
    replaceStrings [ ":" "/" "." "?" "=" ] [ "_" "_" "_" "_" "_" ] (
      concatStringsSep "-" ([ INPUTS_PREFIX ] ++ parts)
    );

  # Compute the generated-flake input name for a module-declared flake input,
  # mirroring `_getModuleInputs` in lib/icedos.nix exactly (single source of
  # truth): `<icedos-<repo>_<module>>-<input>`. A module consuming another
  # repo's input in a *string* context — e.g. a `follows` value like
  # `follows = "${icedosLib.moduleInputName { repo = "github:icedos/providers";
  # module = "jovian"; input = "jovian"; }}/nixpkgs"` — needs the exact
  # top-level name. Inside `outputs.nixosModules` the masked input set already
  # exposes the input under the bare declared name, so this is only required
  # where the name must be spelled out literally.
  moduleInputName =
    {
      repo,
      module,
      input,
    }:
    "${
      mkInputName {
        parts = [
          repo
          module
        ];
      }
    }-${input}";

  # Detect git-transport flake URLs (git+ssh://, git+https://, git+file://, git://, …).
  # These encode rev as a query parameter (?rev=<hash>), not a path segment.
  _urlIsGitScheme = url: stringStartsWith "git+" url || stringStartsWith "git://" url;

  # Read the state flake.lock — the only lock that holds entries for the
  # dynamically-generated repo inputs. Returns null on first build (lock
  # absent) so callers can treat it as "no pin available".
  _readFlakeLock =
    let
      lockPath = "${ICEDOS_STATE_DIR}/flake.lock";
    in
    if pathExists lockPath then fromJSON (readFile lockPath) else null;

  # Determine the revision suffix from flake.lock based on repo name.
  # Returns /{rev}, ?rev={rev} (for git schemes), ?narHash={hash}, or empty string.
  _getRevisionFromLock =
    {
      repoName,
      lock,
      url,
    }:
    let
      hasRev = hasAttrByPath [ "nodes" repoName "locked" "rev" ] lock;
      hasNarHash = hasAttrByPath [ "nodes" repoName "locked" "narHash" ] lock;
    in
    if (builtins.getEnv "ICEDOS_UPDATE" == "1") || (!hasRev && !hasNarHash) then
      ""
    else if hasRev && _urlIsGitScheme url then
      "?rev=${lock.nodes.${repoName}.locked.rev}"
    else if hasRev then
      "/${lock.nodes.${repoName}.locked.rev}"
    else
      "?narHash=${lock.nodes.${repoName}.locked.narHash}";

  # Get the flake revision string (with / or ? prefix if available).
  # If the lockfile entry's `original` describes a different URL than
  # the one we're querying for (i.e. an overrideUrl was just toggled
  # in config.toml), return "" so the input gets re-resolved from
  # scratch instead of trying to apply a stale rev/narHash to a new
  # source. Transitive inputs are unaffected — their `original` urls
  # don't change when overrideUrl toggles, so the match still holds.
  _resolveFlakeRevision =
    {
      url,
      repoName,
    }:
    let
      lock = _readFlakeLock;

      lockedOriginalMatches =
        let
          orig = lock.nodes.${repoName}.original or null;
          type = orig.type or "";
        in
        orig != null
        && (
          if type == "github" || type == "gitlab" || type == "sourcehut" then
            url == "${type}:${orig.owner}/${orig.repo}"
          else if type == "path" then
            url == "path:${orig.path}"
          else if type == "git" then
            url == orig.url || url == "git+${orig.url}"
          else
            false
        );
    in
    if (lock == null) || ((stringStartsWith "path:" url) && (ICEDOS_STAGE == "genflake")) then
      ""
    else if !lockedOriginalMatches then
      ""
    else
      _getRevisionFromLock { inherit repoName lock url; };

  # Split a flake URL of the form `scheme:owner/repo/<ref>` into
  # { baseUrl = "scheme:owner/repo"; ref = "<ref>"; }. Only applies to schemes
  # that encode the ref as the third path segment (github, gitlab, sourcehut).
  # For any other URL shape returns the URL unchanged and ref = null.
  _parseFlakeUrl =
    url:
    let
      match = builtins.match "(github|gitlab|sourcehut):([^/?]+)/([^/?]+)/([^?]+)(.*)" url;
    in
    if match == null then
      {
        baseUrl = url;
        ref = null;
      }
    else
      {
        baseUrl = "${builtins.elemAt match 0}:${builtins.elemAt match 1}/${builtins.elemAt match 2}${builtins.elemAt match 4}";
        ref = builtins.elemAt match 3;
      };

  # Generate a unique key for a module (url/name combination).
  _getModuleKey = url: name: "${url}/${name}";

  # nixpkgs + home-manager are the inputs that actually age the system. Their
  # lastModified is known at eval time (flake inputs, see lib/genflake.nix), so
  # we inject it and only compute the age at runtime. Consumed by status.nix
  # for the input freshness section.
  freshInputs = inputs: [
    {
      name = "nixpkgs";
      lm = inputs.nixpkgs.sourceInfo.lastModified;
    }
    {
      name = "home-manager";
      lm = inputs.home-manager.sourceInfo.lastModified;
    }
  ];
}
