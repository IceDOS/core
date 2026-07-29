{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash) genHelpFlags redString;
  inherit (config.icedos) configurationLocation;
  inherit (config.icedos.system.toolset) configurationCommands;

  jq = "${pkgs.jq}/bin/jq";
  fzf = "${pkgs.fzf}/bin/fzf";
  optionsCache = "${configurationLocation}/.cache/options-doc.json";
  modulesCache = "${configurationLocation}/.cache/modules-doc.json";

  # Extra-config dirs (icedos.system.extraConfigs) as shell-quoted args, so the
  # index-staleness check watches every configured config dir, not just `configs`.
  configDirsArgs = lib.concatStringsSep " " (
    map lib.escapeShellArg config.icedos.system.extraConfigs
  );

  # Render one option's detail: type, description, and a paste-ready TOML
  # snippet showing the option's current value (user override if set, else the
  # resolved default). Reused for both the fzf preview pane and the final
  # selection, so the two never drift. Takes the option name as $1.
  detailBin = pkgs.writeShellScript "icedos-search-detail" ''
    ${jq} -r --arg n "$1" '
      def q: if test("^[A-Za-z0-9_-]+$") then . else @json end;
      def isScalar: type=="string" or type=="number" or type=="boolean" or type=="null";
      def isScalarArray: type=="array" and all(.[]; isScalar);
      def inline:
        if type=="string" then @json
        elif type=="boolean" then tostring
        elif type=="number" then tostring
        elif type=="array" then "[ " + ([.[]|inline]|join(", ")) + " ]"
        else ("" | @json) end;
      def body($p):
        ( to_entries[] | select(.value|(isScalar or isScalarArray)) | (.key|q) + " = " + (.value|inline) ),
        ( to_entries[] | select(.value|type=="object") | (.key|q) as $k | ("[" + $p + "." + $k + "]"), (.value|body($p+"."+$k)) ),
        ( to_entries[] | select(.value|(type=="array" and length>0 and all(.[];type=="object"))) | (.key|q) as $k | .value[] | ("[[" + $p + "." + $k + "]]"), body($p+"."+$k) );
      def emit($name):
        if (isScalar or isScalarArray) then
          ("[" + ($name|sub("\\.[^.]+$";"")) + "]"), (($name|sub("^.*\\.";"")) + " = " + inline)
        elif type=="object" then
          ("[" + $name + "]"), body($name)
        elif (type=="array" and length>0 and all(.[];type=="object")) then
          ( .[] | ("[[" + $name + "]]"), body($name) )
        else (($name|sub("^.*\\.";"")) + " = " + tojson) end;
      (map(select(.name == $n)) | .[0]) as $o
      | if $o == null then empty else
          ( "name:  " + $o.name,
            "type:  " + ($o.type // ""),
            (if (($o.description // "") | length) > 0 then "desc:  " + $o.description else empty end),
            "",
            "toml:",
            ($o.value | emit($o.name)) )
        end
    ' "${optionsCache}"
  '';

  # Render one module's detail (repo, status, description, dependencies) for the
  # fzf preview pane and the final selection. Takes the module name as $1.
  moduleDetailBin = pkgs.writeShellScript "icedos-modules-detail" ''
    ${jq} -r --arg n "$1" '
      (map(select(.name == $n)) | .[0]) as $m
      | if $m == null then empty else
          ( "name:     " + $m.name,
            "repo:     " + $m.repo,
            "status:   " + (if $m.enabled
                            then (if $m.explicit then "● enabled (explicit)" else "◐ enabled (via dependency)" end)
                            else "○ available (not enabled)" end),
            (if (($m.description // "") | length) > 0 then "desc:     " + $m.description else empty end),
            (([$m.dependencies[].modules[]] | unique) as $d
             | if ($d | length) > 0 then "deps:     " + ($d | join(", ")) else empty end),
            (([$m.optionalDependencies[].modules[]] | unique) as $o
             | if ($o | length) > 0 then "optional: " + ($o | join(", ")) else empty end) )
        end
    ' "${modulesCache}"
  '';

  # mtime-based staleness: regenerate the index when config.toml / configs/*.toml
  # / the state lock are newer than either doc (or one is missing). Regen reuses
  # the build app through the state-dir build.sh shim (`nix run path:.`), which
  # sets up the env + PATH the genflake eval needs — the same path `icedos
  # rebuild` takes, so no IceDOS env has to be reconstructed here. Both docs are
  # produced together by `build.sh --export-search-index`.
  ensureIndex = ''
    ensure_index() {
      if [ ! -d "${configurationLocation}" ]; then
        die "configuration path '${configurationLocation}' is invalid; run 'icedos rebuild' once."
      fi

      CONFIG_DIRS=(${configDirsArgs})
      stale=0
      for cache in "${optionsCache}" "${modulesCache}"; do
        [ -f "$cache" ] && [ -s "$cache" ] || stale=1
        for src in "${configurationLocation}/../config.toml" \
                   "${configurationLocation}/flake.lock"; do
          [ -f "$src" ] && [ "$src" -nt "$cache" ] && stale=1
        done
        shopt -s nullglob
        for d in "''${CONFIG_DIRS[@]}"; do
          for src in "${configurationLocation}/../$d/"*.toml "${configurationLocation}/../$d/".*.toml; do
            [ -f "$src" ] && [ "$src" -nt "$cache" ] && stale=1
          done
        done
        shopt -u nullglob
      done

      if [ "$stale" -eq 1 ]; then
        log_step "refreshing configuration index..."
        if ! ( cd "${configurationLocation}" && bash ./build.sh --export-search-index ); then
          if [ -f "${optionsCache}" ] && [ -s "${optionsCache}" ] \
          && [ -f "${modulesCache}" ] && [ -s "${modulesCache}" ]; then
            log_warn "index may be stale — run 'icedos rebuild --build'"
          else
            die "failed to build configuration index (no cache available)"
          fi
        fi
      fi
    }
  '';

  searchCmd = {
    command = "search";
    help = "search icedos options and/or modules";

    completion.command = "printf '%s\\n' --options --modules";

    script = ''
            if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
              echo "Usage: icedos configuration search [--options|--modules] [<name>]"
              echo
              echo "  With no flags, opens an fzf picker over both options and modules."
              echo "  --options [<name>]    fuzzy-search options, or print detail for <name>"
              echo "  --modules [<name>]    browse modules, or print detail for <name>"
              echo
              echo "Examples:"
              echo "  icedos configuration search"
              echo "  icedos configuration search --options"
              echo "  icedos configuration search --options icedos.system.arch"
              echo "  icedos configuration search --modules steam"
              exit 0
            fi

            mode="all"
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --options) mode="options"; shift ;;
                --modules) mode="modules"; shift ;;
                --) shift; break ;;
                --help|-h|help|h) printf '%s\n' \
                  "Usage: icedos configuration search [--options|--modules] [<name>]" \
                  "" \
                  "  With no flags, opens an fzf picker over both options and modules." \
                  "  --options [<name>]    fuzzy-search options, or print detail for <name>" \
                  "  --modules [<name>]    browse modules, or print detail for <name>"
                  exit 0 ;;
                -*) die "unknown flag: $1" ;;
                *) break ;;
              esac
            done

            # Fail fast on bad args before paying for index refresh
            case "$mode" in
              all)
                [ "$#" -gt 0 ] && die "unknown arg: $1"
                ;;
              options|modules)
                [ "$#" -gt 1 ] && die "unknown arg: $2"
                ;;
            esac

            # In non-TTY mode (piped), redirect index chatter to stderr so
            # machine-readable output stays clean.
      ${ensureIndex}
            if [ ! -t 1 ]; then
              ensure_index 1>&2
            else
              ensure_index
            fi

            options_list() {
              ${jq} -r 'sort_by(.name)[] | [ .name, (.type // "") ] | @tsv' "${optionsCache}"
            }
            modules_list() {
              ${jq} -r 'sort_by(.name)[] | .name' "${modulesCache}"
            }
            search_list() {
              ${jq} -r '.[] | "option::" + .name' "${optionsCache}"
              ${jq} -r '.[] | "module::" + .name' "${modulesCache}"
            }

            run_options() {
              if [ -n "$1" ]; then
                detail=$(${detailBin} "$1")
                [ -z "$detail" ] && die "unknown option: $1 (run 'icedos configuration search --options' to browse)"
                printf '%s\n' "$detail"
                exit 0
              fi
              if [ ! -t 1 ]; then
                options_list
                exit 0
              fi
              sel=$(options_list \
                | ${fzf} --delimiter='\t' --with-nth=1 \
                         --prompt='option> ' \
                         --layout=reverse --height=80% --border \
                         --preview '${detailBin} {1}' \
                         --preview-window='right,60%,wrap' \
                | cut -f1)
              [ -z "$sel" ] && exit 0
              ${detailBin} "$sel"
            }

            run_modules() {
              if [ -n "$1" ]; then
                detail=$(${moduleDetailBin} "$1")
                [ -z "$detail" ] && die "unknown module: $1 (run 'icedos configuration search --modules' to browse)"
                printf '%s\n' "$detail"
                exit 0
              fi
              if [ ! -t 1 ]; then
                modules_list
                exit 0
              fi
              sel=$(modules_list \
                | ${fzf} --prompt='module> ' \
                         --layout=reverse --height=80% --border \
                         --preview '${moduleDetailBin} {}' \
                         --preview-window='right,60%,wrap')
              [ -z "$sel" ] && exit 0
              ${moduleDetailBin} "$sel"
            }

            run_all() {
              if [ ! -t 1 ]; then
                search_list | sort
                exit 0
              fi
              sel=$(search_list | sort \
                | ${fzf} --delimiter='::' --with-nth=2 \
                         --prompt='search> ' \
                         --layout=reverse --height=80% --border \
                         --preview '
                           t={1} n={2}
                           if [ "$t" = "option" ]; then
                             ${detailBin} "$n"
                           else
                             ${moduleDetailBin} "$n"
                           fi
                         ' \
                         --preview-window='right,60%,wrap')
              [ -z "$sel" ] && exit 0
              t="''${sel%%::*}" n="''${sel#*::}"
              if [ "$t" = "option" ]; then
                ${detailBin} "$n"
              else
                ${moduleDetailBin} "$n"
              fi
            }

            case "$mode" in
              options) run_options "$@" ;;
              modules) run_modules "$@" ;;
              all)     run_all ;;
            esac
    '';
  };

  validateConfig = {
    command = "validate";
    help = "validate icedos config without a full rebuild (schema-only, fast)";

    script = ''
      if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
        echo "Usage: icedos configuration validate"
        echo "Validates your icedos config (config.toml + configs/*.toml) by"
        echo "running the genflake eval — checks types, schema, unknown keys,"
        echo "and missing modules. Exits 0 if valid, non-zero if not."
        echo "Scope: the genflake stage only. Errors inside module bodies and"
        echo "option collisions between modules still surface at rebuild time,"
        echo "since no system closure is evaluated here."
        echo "Side effects: none beyond refreshing the search index that"
        echo "'icedos configuration search' reads (.cache/*-doc.json)."
        exit 0
      fi

      if [ "$#" -gt 0 ]; then
        echo -e "${redString "Unknown arg"}: $1" >&2
        exit 1
      fi

      if [ ! -d "${configurationLocation}" ]; then
        die "configuration path '${configurationLocation}' is invalid; run 'icedos rebuild' once."
      fi

      log_step "validating configuration..."

      if out="$( cd "${configurationLocation}" && bash ./build.sh --export-search-index 2>&1 )"; then
        log_ok "configuration is valid"
      else
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        die "configuration validation failed"
      fi
    '';
  };
in
{
  icedos.system.toolset.commands = [
    {
      command = "configuration";
      help = "inspect your icedos configuration";

      commands = [
        searchCmd
        validateConfig
        {
          command = "refresh";
          help = "rebuild the search index (options + modules)";
          script = ''
            if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
              echo "Usage: icedos configuration refresh"
              echo "Forces a rebuild of the options and modules search index"
              echo "(.cache/*-doc.json) that 'icedos configuration search' reads."
              echo "This is the same index that is auto-refreshed when stale."
              exit 0
            fi

            [ "$#" -gt 0 ] && die "unknown arg: $1"

            if [ ! -d "${configurationLocation}" ]; then
              die "configuration path '${configurationLocation}' is invalid; run 'icedos rebuild' once."
            fi

            log_step "refreshing configuration index..."
            if ! ( cd "${configurationLocation}" && bash ./build.sh --export-search-index ); then
              die "failed to refresh configuration index"
            fi
            log_ok "configuration index refreshed"
          '';
        }
      ]
      ++ configurationCommands;
    }
  ];
}
