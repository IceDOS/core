{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash) genHelpFlags;
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
    if [ ! -d "${configurationLocation}" ]; then
      die "configuration path '${configurationLocation}' is invalid; run 'icedos rebuild' once."
    fi

    CONFIG_DIRS=(${configDirsArgs})
    stale=0
    for cache in "${optionsCache}" "${modulesCache}"; do
      [ -f "$cache" ] || stale=1
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
      ( cd "${configurationLocation}" && bash ./build.sh --export-search-index ) \
        || die "failed to build configuration index"
    fi
  '';

  showOptions = {
    command = "options";
    help = "fuzzy-search icedos options (fzf), with a paste-ready toml snippet";

    # Tab-complete option names straight from the cache — no fzf, no index
    # rebuild. Missing cache (jq error) is swallowed so completion never blocks.
    completion.command = "${jq} -r 'sort_by(.name)[] | .name' \"${optionsCache}\" 2>/dev/null";

    script = ''
      if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
        echo "Usage: icedos configuration show options [<name>]"
        echo "With no argument, opens an fzf picker over all icedos options. With an"
        echo "option name, prints that option's type, description, and a paste-ready"
        echo "toml snippet directly — no fzf, scriptable."
        exit 0
      fi

      ${ensureIndex}

      # Named lookup: `... show options <name>` prints one option's detail
      # (type, description, paste-ready toml) straight to stdout, bypassing fzf —
      # useful for scripting and quick lookups. Empty render = no such option.
      if [ -n "$1" ]; then
        detail=$(${detailBin} "$1")
        [ -z "$detail" ] && die "unknown option: $1 (run 'icedos configuration show options' to browse)"
        printf '%s\n' "$detail"
        exit 0
      fi

      # Sorted "name<TAB>type" stream of every option.
      options_list() {
        ${jq} -r 'sort_by(.name)[] | [ .name, (.type // "") ] | @tsv' "${optionsCache}"
      }

      # Non-interactive (pipes): emit the sorted list and exit.
      if [ ! -t 1 ]; then
        options_list
        exit 0
      fi

      # Default: fzf picker. Preview renders the option detail; selecting one
      # prints the same detail to stdout for copy/paste.
      sel=$(options_list \
        | ${fzf} --delimiter='\t' --with-nth=1 \
                 --prompt='option> ' \
                 --layout=reverse --height=80% --border \
                 --preview '${detailBin} {1}' \
                 --preview-window='right,60%,wrap' \
        | cut -f1)

      [ -z "$sel" ] && exit 0
      ${detailBin} "$sel"
    '';
  };

  showModules = {
    command = "modules";
    help = "show the icedos module graph (enabled, available, dependencies)";

    # Tab-complete module names straight from the cache — no fzf, no index
    # rebuild. Missing cache (jq error) is swallowed so completion never blocks.
    completion.command = "${jq} -r 'sort_by(.name)[] | .name' \"${modulesCache}\" 2>/dev/null";

    script = ''
      if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
        echo "Usage: icedos configuration show modules [<name>]"
        echo "With no argument, opens an fzf picker over every module (configured +"
        echo "dependency repos). With a module name, prints that module's repo, status,"
        echo "description, and dependencies directly — no fzf, scriptable."
        exit 0
      fi

      ${ensureIndex}

      # Named lookup: `... show modules <name>` prints one module's detail
      # (repo, status, description, deps) straight to stdout, bypassing fzf —
      # useful for scripting and quick lookups. Empty render = no such module.
      if [ -n "$1" ]; then
        detail=$(${moduleDetailBin} "$1")
        [ -z "$detail" ] && die "unknown module: $1 (run 'icedos configuration show modules' to browse)"
        printf '%s\n' "$detail"
        exit 0
      fi

      # fzf feed: sorted module names. Status markers live in the preview, not
      # the list.
      modules_list() {
        ${jq} -r 'sort_by(.name)[] | .name' "${modulesCache}"
      }

      # Non-interactive (pipes): emit the sorted name list and exit.
      if [ ! -t 1 ]; then
        modules_list
        exit 0
      fi

      # Default: fzf picker over module names; preview renders the module detail
      # (repo, status, deps); selecting one prints that detail to stdout.
      sel=$(modules_list \
        | ${fzf} --prompt='module> ' \
                 --layout=reverse --height=80% --border \
                 --preview '${moduleDetailBin} {}' \
                 --preview-window='right,60%,wrap')

      [ -z "$sel" ] && exit 0
      ${moduleDetailBin} "$sel"
    '';
  };
in
{
  icedos.system.toolset.commands = [
    {
      command = "configuration";
      help = "inspect your icedos configuration";

      commands = [
        {
          command = "show";
          help = "show icedos options and modules";

          commands = [
            showOptions
            showModules
          ];
        }
      ]
      ++ configurationCommands;
    }
  ];
}
