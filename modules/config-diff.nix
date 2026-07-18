{
  config,
  icedosLib,
  lib,
  ...
}:

let
  inherit (icedosLib.bash) genHelpFlags;
  inherit (config.icedos) configurationLocation;

  cacheDir = "${configurationLocation}/.cache";
  configRoot = "${configurationLocation}/..";
  workingConfig = "${configRoot}/config.toml";

  # Extra-config dirs (icedos.system.extraConfigs) as shell-quoted args.
  configDirsArgs = lib.concatStringsSep " " (
    map lib.escapeShellArg config.icedos.system.extraConfigs
  );
in
{
  icedos.system.toolset.configurationCommands = [
    {
      command = "diff";
      help = "diff working config set against the last rebuilt snapshot";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos configuration diff"
          echo "Diffs your working config set (config.toml + every *.toml under your"
          echo "config dirs, including hidden .*.toml) against the config that built the"
          echo "current system (your pending, un-rebuilt changes)."
          exit 0
        fi

        CONFIG_DIRS=(${configDirsArgs})

        # Latest config snapshot (see rebuild.nix snapshot_config_set): the folder
        # carries the .config-set marker plus config.toml (optional) + every
        # extraConfigs dir for the rebuild where the set last changed. Glob is
        # lexically sorted → chronological for date -Is names, so the last match
        # is the most recent.
        shopt -s nullglob
        latest=""
        for d in "${cacheDir}"/*/; do
          [ -f "''${d}.config-set" ] && latest="$d"
        done
        shopt -u nullglob

        [ -n "$latest" ] || die "no config snapshots yet — run 'icedos rebuild' once"

        l1="$(basename "$latest") (last build)"

        # Diff one snapshot/working pair; prints a unified diff and flags
        # `differs` on mismatch. A missing side shows as /dev/null so files
        # added or removed since the last build are visible.
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

        diff_pair "config.toml" "''${latest}config.toml" "${workingConfig}"

        # For each configured dir: union of snapshot + working *.toml (incl.
        # hidden), name-sorted, each pair diffed.
        shopt -s nullglob
        for d in "''${CONFIG_DIRS[@]}"; do
          cfg_names="$(
            for f in "''${latest}$d/"*.toml "''${latest}$d/".*.toml \
                     "${configRoot}/$d/"*.toml "${configRoot}/$d/".*.toml; do
              basename "$f"
            done | sort -u
          )"
          while IFS= read -r b; do
            [ -n "$b" ] || continue
            diff_pair "$d/$b" "''${latest}$d/$b" "${configRoot}/$d/$b"
          done <<< "$cfg_names"
        done
        shopt -u nullglob

        if [ "$differs" -eq 0 ]; then
          log_ok "no differences ($l1 → working tree)"
        fi
      '';
    }
  ];
}
