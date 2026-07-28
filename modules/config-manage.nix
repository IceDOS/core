{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash) dimGreenString redString;
  inherit (config.icedos) configurationLocation;

  jq = "${pkgs.jq}/bin/jq";
  modulesCache = "${configurationLocation}/.cache/modules-doc.json";

  configDirsArgs = lib.concatStringsSep " " (
    map lib.escapeShellArg config.icedos.system.extraConfigs
  );

  stripRepoRef = ''
    strip_repo_ref() {
      local url="$1"
      case "$url" in
        github:*|gitlab:*|sourcehut:*)
          echo "$url" | cut -d/ -f1-2
          ;;
        *)
          echo "$url"
          ;;
      esac
    }
  '';

  tomlEdit = pkgs.writeScript "toml-edit" ''
    #!${pkgs.python3.withPackages (ps: [ ps.tomlkit ])}/bin/python3
    import sys
    import tomlkit

    def strip_repo_ref(url):
        if url.startswith(("github:", "gitlab:", "sourcehut:")):
            parts = url.split("/")
            return "/".join(parts[:2])
        return url

    action = sys.argv[1]

    if action in ("find-repo", "find-entry", "enable", "disable"):
        config_path = sys.argv[2]
        repo_url = sys.argv[3]
    else:
        sys.exit(2)

    with open(config_path) as f:
        doc = tomlkit.parse(f.read())

    if doc.get("enable") is False:
        sys.exit(1)

    repos = doc.get("icedos", {}).get("repositories")
    if repos is None:
        sys.exit(1)

    needle = strip_repo_ref(repo_url)
    for repo in repos:
        if strip_repo_ref(repo.get("url", "")) != needle:
            continue

        if action == "find-repo":
            sys.exit(0)

        modules = repo.get("modules")
        if modules is None:
            modules = tomlkit.array()
            repo["modules"] = modules

        if action == "find-entry":
            sys.exit(0 if sys.argv[4] in modules else 1)

        mod_name = sys.argv[4]
        dry_run = "--dry" in sys.argv

        if action == "enable":
            if mod_name not in modules:
                modules.append(mod_name)
        elif action == "disable":
            while mod_name in modules:
                modules.remove(mod_name)

        if dry_run:
            sys.stdout.write(tomlkit.dumps(doc))
        else:
            with open(config_path, "w") as f:
                f.write(tomlkit.dumps(doc))
        sys.exit(0)

    sys.exit(1)
  '';

  ensureIndex = ''
    if [ ! -d "${configurationLocation}" ]; then
      die "configuration path '${configurationLocation}' is invalid; run 'icedos rebuild' once."
    fi

    CONFIG_DIRS=(${configDirsArgs})
    stale=0
    [ -f "${modulesCache}" ] && [ -s "${modulesCache}" ] || stale=1
    for src in "${configurationLocation}/../config.toml" \
               "${configurationLocation}/flake.lock"; do
      [ -f "$src" ] && [ "$src" -nt "${modulesCache}" ] && stale=1
    done
    shopt -s nullglob
    for d in "''${CONFIG_DIRS[@]}"; do
      for src in "${configurationLocation}/../$d/"*.toml "${configurationLocation}/../$d/".*.toml; do
        [ -f "$src" ] && [ "$src" -nt "${modulesCache}" ] && stale=1
      done
    done
    shopt -u nullglob

    if [ "$stale" -eq 1 ]; then
      log_step "refreshing configuration index..."
      if ! ( cd "${configurationLocation}" && bash ./build.sh --export-search-index ); then
        if [ -f "${modulesCache}" ] && [ -s "${modulesCache}" ]; then
          log_warn "index may be stale — run 'icedos rebuild --build'"
        else
          die "failed to build configuration index (no cache available)"
        fi
      fi
    fi
  '';

  findRepoFile = ''
    find_repo_file() {
      local repo_url="$1" need_mod="$2" f best=""

      f="${configurationLocation}/../config.toml"
      if [ -f "$f" ] && PYTHONIOENCODING=utf-8 ${tomlEdit} find-repo "$f" "$repo_url" 2>/dev/null; then
        if [ -z "$need_mod" ] || PYTHONIOENCODING=utf-8 ${tomlEdit} find-entry "$f" "$repo_url" "$need_mod" 2>/dev/null; then
          printf '%s' "$f"; return 0
        fi
        best="$f"
      fi

      CONFIG_DIRS=(${configDirsArgs})
      shopt -s nullglob
      for d in "''${CONFIG_DIRS[@]}"; do
        for f in "${configurationLocation}/../$d/"*.toml "${configurationLocation}/../$d/".*.toml; do
          PYTHONIOENCODING=utf-8 ${tomlEdit} find-repo "$f" "$repo_url" 2>/dev/null || continue
          if [ -n "$need_mod" ] && PYTHONIOENCODING=utf-8 ${tomlEdit} find-entry "$f" "$repo_url" "$need_mod" 2>/dev/null; then
            printf '%s' "$f"; shopt -u nullglob; return 0
          fi
          [ -z "$best" ] && best="$f"
        done
      done
      shopt -u nullglob

      if [ -n "$best" ]; then printf '%s' "$best"; return 0; fi
      return 1
    }
  '';

  mkCommand =
    {
      command,
      verb,
      pastVerb,
      action,
    }:
    let
      explicitFilter = if action == "enable" then "false" else "true";
      usageText = ''
        echo "Usage: icedos configuration ${command} <name> [--dry]"
        echo "${verb} an icedos module by name."
        echo
        echo "  --dry    show what would change without writing"
        echo "  <repo>#<name>  disambiguate when same name exists in multiple repos"
      '';
    in
    {
      inherit command;
      help = "${verb} an icedos module by name";

      completion.command = "${jq} -r 'sort_by(.name)[] | select(.explicit == ${explicitFilter}) | .name' \"${modulesCache}\" 2>/dev/null";

      script = ''
        DRY=0
        MODULE_NAME=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --help|-h)
              ${usageText}
              exit 0
              ;;
            --dry|-n) DRY=1; shift ;;
            -*)
              echo -e "${redString "Unknown arg"}: $1" >&2
              exit 1
              ;;
            *)
              [ -z "$MODULE_NAME" ] || die "only one module name allowed"
              MODULE_NAME="$1"
              shift
              ;;
          esac
        done
        [ -z "$MODULE_NAME" ] && die "usage: icedos configuration ${command} <name>"

        REPO_FILTER=""
        case "$MODULE_NAME" in
          *#*)
            REPO_FILTER="''${MODULE_NAME%%#*}"
            MODULE_NAME="''${MODULE_NAME#*#}"
            ;;
        esac

        ${ensureIndex}

        if [ -n "$REPO_FILTER" ]; then
          MODULE_JSON=$("${jq}" -r --arg n "$MODULE_NAME" --arg r "$REPO_FILTER" '
            map(select(.name == $n and (.repo | contains($r)))) | .[0] // empty
          ' "${modulesCache}")
        else
          MODULE_JSON=$("${jq}" -r --arg n "$MODULE_NAME" '
            map(select(.name == $n)) as $m
            | if ($m | length) > 1 then
                "error: module '"'"'" + $n + "'"'"' exists in repos: " + ([$m[].repo] | join(", "))
                + "; use <repo>#" + $n + " to disambiguate"
              else $m[0] // empty end
          ' "${modulesCache}")
        fi
        [ -z "$MODULE_JSON" ] && die "unknown module '$MODULE_NAME'"
        case "$MODULE_JSON" in
          error:*) die "$MODULE_JSON" ;;
        esac

        REPO_URL=$(printf '%s' "$MODULE_JSON" | "${jq}" -r '.repo // ""')
        IS_ENABLED=$(printf '%s' "$MODULE_JSON" | "${jq}" -r '.enabled // false')
        IS_EXPLICIT=$(printf '%s' "$MODULE_JSON" | "${jq}" -r '.explicit // false')
        [ -z "$REPO_URL" ] && die "cannot determine repo for module '$MODULE_NAME'"

        ${stripRepoRef}
        REPO_BASE=$(strip_repo_ref "$REPO_URL")

        if [ "${action}" = "enable" ]; then
          [ "$IS_ENABLED" = "true" ] && [ "$IS_EXPLICIT" = "true" ] && \
            die "module '$MODULE_NAME' is already enabled"
        else
          [ "$IS_ENABLED" != "true" ] && die "module '$MODULE_NAME' is not enabled"
          [ "$IS_EXPLICIT" != "true" ] && \
            die "module '$MODULE_NAME' is a dependency (enable it explicitly first)"
        fi

        ${findRepoFile}
        SEARCH_MOD="$MODULE_NAME"
        [ "${action}" = "enable" ] && SEARCH_MOD=""
        CONFIG_FILE=$(find_repo_file "$REPO_BASE" "$SEARCH_MOD") \
          || die "no config file declares repo '$REPO_BASE'"

        if [ "${action}" = "disable" ]; then
          PYTHONIOENCODING=utf-8 ${tomlEdit} find-entry "$CONFIG_FILE" "$REPO_BASE" "$MODULE_NAME" \
            2>/dev/null || die "module '$MODULE_NAME' not found in $(basename "$CONFIG_FILE")"
        fi

        if [ "$DRY" -eq 1 ]; then
          echo "=== dry run ==="
          DRY_OUTPUT=$(PYTHONIOENCODING=utf-8 ${tomlEdit} "${action}" "$CONFIG_FILE" "$REPO_BASE" "$MODULE_NAME" --dry) \
            || die "TOML edit failed"
          printf '%s\n' "$DRY_OUTPUT" | diff -u --color=always "$CONFIG_FILE" - || true
          exit 0
        fi

        BACKUP="''${CONFIG_FILE}.bak"
        cp "$CONFIG_FILE" "$BACKUP" || die "failed to create backup"

        PYTHONIOENCODING=utf-8 ${tomlEdit} "${action}" "$CONFIG_FILE" "$REPO_BASE" "$MODULE_NAME" \
          || die "TOML edit failed — backup at $BACKUP"

        rm -f "$BACKUP"
        log_ok "module '$MODULE_NAME' ${pastVerb} in $(basename "$CONFIG_FILE")"
        echo -e "${dimGreenString ">"} Run 'icedos rebuild --build' to apply."
      '';
    };
in
{
  icedos.system.toolset.configurationCommands = [
    (mkCommand {
      command = "enable";
      verb = "Enable";
      pastVerb = "enabled";
      action = "enable";
    })
    (mkCommand {
      command = "disable";
      verb = "Disable";
      pastVerb = "disabled";
      action = "disable";
    })
  ];
}
