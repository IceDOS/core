{
  config,
  icedosLib,
  ...
}:

let
  inherit (icedosLib.bash) configSet genHelpFlags;
  inherit (configSet config) walk;
in
{
  icedos.system.toolset.configurationCommands = [
    {
      command = "diff";
      help = "diff working config set against the snapshot that built the running system";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos configuration diff"
          echo "Diffs your working config set (config.toml + every *.toml under your"
          echo "config dirs, including hidden .*.toml) against the config that built the"
          echo "current system (your pending, un-rebuilt changes)."
          exit 0
        fi

        ${walk}

        built_snapshot
        [ -n "$snapshot" ] || die "no config snapshots yet — run 'icedos rebuild' once"
        latest="$snapshot"
        l1="$snapshot_label"

        # Diff one snapshot/working pair. A missing side shows as /dev/null, so
        # adds and removes are visible.
        differs=0
        diff_pair() {
          local label="$1" snap="$2" work="$3"
          [ -f "$snap" ] || snap=/dev/null
          [ -f "$work" ] || work=/dev/null
          if ! diff -q "$snap" "$work" >/dev/null 2>&1; then
            differs=1
            diff -u --color=always --label "$l1: $label" --label "working tree: $label" \
              "$snap" "$work" || true
          fi
        }

        walk_config_set "$latest" diff_pair

        if [ "$differs" -eq 0 ]; then
          log_ok "no differences ($l1 → working tree)"
        fi
      '';
    }
  ];

  icedos.system.tips.list = [
    "icedos configuration diff shows what you changed since the last rebuild."
  ];
}
