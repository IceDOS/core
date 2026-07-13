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
        in
        ''
          _icedos() {
              local cur="''${COMP_WORDS[COMP_CWORD]}"
              local -a _icedos_args=("''${COMP_WORDS[@]:1:$((COMP_CWORD - 1))}")
              local IFS=' '
              local key="''${_icedos_args[*]}"
              local words=""
              case "$key" in
          ${concatMapStrings (l: "      " + fileLeafArm l) fileLeaves}${
            concatMapStrings (b: "      " + branchArm b) branches
          }      esac
              COMPREPLY=( $(compgen -W "$words" -- "$cur") )
          }
          complete -F _icedos icedos
        '';

      mkZshCompletion =
        { commands }:
        let
          branches = walkBranches commands;
          fileLeaves = walkFileLeaves commands;
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
        in
        ''
          #compdef icedos
          _icedos() {
              local -a path entries
              local key
              path=("''${(@)words[2,$((CURRENT - 1))]}")
              key="''${(j: :)path}"
              entries=()
              case "$key" in
          ${concatMapStrings (l: "      " + fileLeafArm l) fileLeaves}${
            concatMapStrings (b: "      " + branchArm b) branches
          }      esac
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
        in
        ''
          function __icedos_complete_path
              set -l tokens (commandline -opc)
              set -l cur (commandline -ct)
              set -e tokens[1]
              if test -n "$cur"; and set -q tokens[1]
                  set -e tokens[-1]
              end
              string join ' ' -- $tokens
          end

          function __icedos_path_match
              set -l p (__icedos_complete_path)
              test "$p" = "$argv[1]"; and return 0
              string match -q -- "$argv[1] *" "$p"
          end

          function __icedos_complete
              switch (__icedos_complete_path)
          ${concatMapStrings (b: "        " + caseArm b) branches}    end
          end

          complete -c icedos -f -a '(__icedos_complete)'
          ${concatMapStrings fileLeafComplete fileLeaves}'';
    };

  # Authoritative libadwaita named-accent → hex map. Mirrors GNOME 47+
  # `org/gnome/desktop/interface.accent-color` enum and libadwaita's
  # `_palette.scss`. Bare hex (no `#`) so callers can pick the form.
  libadwaitaAccentHex = {
    blue = "3584e4";
    green = "3a944a";
    orange = "ed5b00";
    pink = "d56199";
    purple = "9141ac";
    red = "e62d42";
    slate = "6f8396";
    teal = "2190a4";
    yellow = "c88800";
  };

  # Single source of truth for `icedos.desktop.accentColor` resolution.
  # Accepts a libadwaita name, a base16 slot (`base08`..`base0F`, only
  # meaningful when stylix is on), or a hex (`RRGGBB` / `#RRGGBB`).
  # Empty → "purple". Returns:
  #   { hex; hexNoHash; name; slot; warning; gnomeOn; stylixOn; }
  # `warning` is non-null when GNOME is on but the input is not a libadwaita
  # named accent — `org/gnome/desktop/interface.accent-color` is a string
  # enum, so a slot/hex input causes the GNOME shell to render a fallback
  # name while libadwaita apps render the user's hex.
  generateAccent =
    config:
    let
      inherit (lib)
        elem
        hasAttr
        removePrefix
        toLower
        ;

      desktopCfg = config.icedos.desktop;
      raw = desktopCfg.accentColor;

      gnomeOn = hasAttr "gnome" desktopCfg;
      stylixOn = config.stylix.enable or false;

      namedAccents = attrNames libadwaitaAccentHex;

      # base16 slot inverse — only used when input is a slot and we still
      # need a libadwaita name (e.g. for the GNOME dconf write under stylix).
      # Mirrors the bundled `adwaita` handler in
      # desktop/modules/stylix/lib.nix.
      defaultSlotToName = {
        base08 = "red";
        base09 = "orange";
        base0A = "yellow";
        base0B = "green";
        base0C = "teal";
        base0D = "blue";
        base0E = "purple";
        base0F = "slate";
      };

      isHex = s: builtins.match "#?[0-9a-fA-F]{6}" s != null;
      isName = s: elem (toLower s) namedAccents;
      isSlot = s: builtins.match "base0[89A-Fa-f]" s != null;

      input = if raw == "" then "purple" else raw;

      name =
        if isName input then
          toLower input
        else if isSlot input then
          defaultSlotToName.${input} or "blue"
        else
          "blue";

      hexNoHash =
        if isHex input then
          removePrefix "#" input
        else if isSlot input && stylixOn then
          config.lib.stylix.colors.${input}
        else
          libadwaitaAccentHex.${name};

      hex = "#${hexNoHash}";

      slot = if isSlot input then input else null;

      warning =
        if gnomeOn && !(isName input) then
          "icedos.desktop.accentColor: GNOME is enabled but `${input}` is not a libadwaita named accent. The GNOME shell will use `${name}`; libadwaita apps and other consumers will use `${hex}`. Set accentColor to one of ${concatStringsSep ", " namedAccents} to keep them in sync."
        else
          null;
    in
    {
      inherit
        hex
        hexNoHash
        name
        slot
        warning
        gnomeOn
        stylixOn
        ;
    };

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

  desktop = {
    # Build a GNOME `org.gnome.desktop.wm.preferences/button-layout` string
    # from per-button visibility flags. Fed to GNOME directly and to Zed's
    # `title_bar.button_layout` (which parses the same format via
    # `WindowButtonLayout::parse` in `crates/gpui/src/platform.rs`).
    # Empty button list yields `"appmenu:"`, hiding all three.
    mkButtonLayoutString =
      {
        minimizeButton,
        maximizeButton,
        ...
      }:
      let
        # Close is always present (no opt-out): semantically required, and
        # several compositors (COSMIC) ignore hide-close anyway.
        buttons = concatStringsSep "," (
          optional minimizeButton "minimize" ++ optional maximizeButton "maximize" ++ [ "close" ]
        );
      in
      "appmenu:${buttons}";

    # Returns the active accent color as a 6-char hex string (no `#`),
    # used by per-WM modules to colour focused-window borders /
    # active-hint indicators. Wraps `generateAccent` so all consumers
    # share the same name/slot/hex resolution rules.
    accentHex = config: (generateAccent config).hexNoHash;
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

  systemd = {
    # Returns the *-session.target names for whichever icedos.desktop.*
    # DEs are present on this host, derived from the full `config.icedos`
    # attrset (the `cfg` modules already destructure to). Use for
    # systemd.user.services' `Unit.After` (after prepending
    # `graphical-session.target`) and `Install.WantedBy`. Adding a new DE
    # means appending one line here, not editing every consumer.
    desktopSessionTargets =
      cfg:
      let
        present = name: hasAttr "desktop" cfg && hasAttr name cfg.desktop;
      in
      optional (present "cosmic") "cosmic-session.target"
      ++ optional (present "gnome") "gnome-session.target"
      ++ optional (present "hyprland") "hyprland-session.target"
      ++ optional (present "kde") "plasma-workspace-wayland.target";
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

  inputIsOverride = { input }: (hasAttr "override" input) && input.override;
  inputHasPatches = { input }: (hasAttr "patches" input) && builtins.length input.patches > 0;

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
}
