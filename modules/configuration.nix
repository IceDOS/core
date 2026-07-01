{
  config,
  icedosLib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash) genHelpFlags;
  inherit (config.icedos) configurationLocation;

  jq = "${pkgs.jq}/bin/jq";
  fzf = "${pkgs.fzf}/bin/fzf";
  optionsCache = "${configurationLocation}/.cache/options-doc.json";
  modulesCache = "${configurationLocation}/.cache/modules-doc.json";

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

  # mtime-based staleness: regenerate the index when config.toml / .private.toml
  # / the state lock are newer than either doc (or one is missing). Regen reuses
  # the build app through the state-dir build.sh shim (`nix run path:.`), which
  # sets up the env + PATH the genflake eval needs — the same path `icedos
  # rebuild` takes, so no IceDOS env has to be reconstructed here. Both docs are
  # produced together by `build.sh --export-search-index`.
  ensureIndex = ''
    if [ ! -d "${configurationLocation}" ]; then
      die "configuration path '${configurationLocation}' is invalid; run 'icedos rebuild' once."
    fi

    stale=0
    for cache in "${optionsCache}" "${modulesCache}"; do
      [ -f "$cache" ] || stale=1
      for src in "${configurationLocation}/../config.toml" \
                 "${configurationLocation}/../.private.toml" \
                 "${configurationLocation}/flake.lock"; do
        [ -f "$src" ] && [ "$src" -nt "$cache" ] && stale=1
      done
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

    script = ''
      if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
        echo "Usage: icedos configuration show options"
        echo "Opens an fzf picker over all icedos options; the preview shows each"
        echo "option's type, description, and a paste-ready toml snippet."
        exit 0
      fi

      ${ensureIndex}

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

    script = ''
      if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
        echo "Usage: icedos configuration show modules"
        echo "Opens an fzf picker over every module (configured + dependency repos);"
        echo "the preview shows each module's repo, status, description, and dependencies."
        exit 0
      fi

      ${ensureIndex}

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
      ];
    }
  ];
}
