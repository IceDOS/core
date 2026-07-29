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
  optionsCache = "${configurationLocation}/.cache/options-doc.json";
in
{
  icedos.system.toolset.configurationCommands = [
    {
      command = "get";
      help = "print the effective value of an icedos option at a dotted path";

      completion.command = "${jq} -r 'sort_by(.name)[] | .name' \"${optionsCache}\" 2>/dev/null";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos configuration get <option.path>"
          echo
          echo "Prints the effective value (user override → module default) of an"
           echo "icedos option. Works for any option shown by 'icedos configuration"
           echo "search --options'. For scripting: the output is a bare value —"
          echo "string, number, bool, or JSON for compound types."
          echo
          echo "Examples:"
          echo "  icedos configuration get icedos.system.version"
          echo "  icedos configuration get icedos.system.allowUnfree"
          echo "  icedos configuration get icedos.system.packages"
          exit 0
        fi

        [ -n "$1" ] || die "usage: icedos configuration get <path>"
        [ -f "${optionsCache}" ] || die "no options cache; run 'icedos rebuild --build' once"

        result=$(${jq} -r --arg p "$1" '
          (map(select(.name == $p)) | .[0]) as $o
          | if $o == null then "__MISSING__"
            elif $o.value == null then "null"
            elif $o.value | type == "string" then $o.value
            elif $o.value | type == "bool" then if $o.value then "true" else "false" end
            elif $o.value | type == "number" then $o.value | tostring
            else $o.value | tojson
            end
        ' "${optionsCache}")

        if [ "$result" = "__MISSING__" ]; then
          die "no such option: $1 (run 'icedos configuration search --options' to browse)"
        fi
        printf '%s\n' "$result"
      '';
    }
  ];
}
