{
  config,
  icedosLib,
  ...
}:

let
  inherit (icedosLib.bash) genHelpFlags;
  inherit (config.icedos) configurationLocation;

  cacheDir = "${configurationLocation}/.cache";
  workingConfig = "${configurationLocation}/../config.toml";
in
{
  icedos.system.toolset.configurationCommands = [
    {
      command = "diff";
      help = "diff working config.toml against the last rebuilt snapshot (pending changes)";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos configuration diff"
          echo "Diffs your working config.toml against the config that built the current"
          echo "system (i.e. your pending, un-rebuilt changes)."
          exit 0
        fi

        # Latest config-bearing snapshot. The cache de-dups per file, so a
        # timestamp folder holds a config.toml only for the rebuild where
        # config.toml changed. Glob is lexically sorted → chronological for
        # `date -Is` names, so the last match is the most recent.
        shopt -s nullglob
        latest=""
        for d in "${cacheDir}"/*/; do
          [ -f "''${d}config.toml" ] && latest="$d"
        done
        shopt -u nullglob

        [ -n "$latest" ] || die "no config snapshots yet — run 'icedos rebuild' once"
        [ -f "${workingConfig}" ] || die "working config.toml not found"

        l1="$(basename "$latest") (last build)"
        if diff -q "''${latest}config.toml" "${workingConfig}" >/dev/null 2>&1; then
          log_ok "no differences ($l1 → working tree)"
        else
          diff -u --color=always --label "$l1" --label "working tree" \
            "''${latest}config.toml" "${workingConfig}" || true
        fi
      '';
    }
  ];
}
