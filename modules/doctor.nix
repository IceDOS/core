{
  config,
  icedosLib,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash) genHelpFlags purpleString;
  inherit (config.icedos.system.gc) automatic interval;
  inherit (config.icedos.system.cache) enable key;

  nixBin = "${config.nix.package}/bin/nix";
  systemctl = "${pkgs.systemd}/bin/systemctl";

  # Substituters the system pulls from, read from Nix settings at eval time —
  # the same list state.nix writes to /etc/icedos/substituters.
  subList = with config.nix.settings; substituters ++ trusted-substituters;

  # nixpkgs + home-manager are the inputs that actually age the system. Their
  # lastModified is known at eval time (flake inputs, see genflake.nix), so we
  # inject it and only compute the age at runtime. This reflects the inputs that
  # built the RUNNING system, not a flake.lock that may be updated but unbuilt.
  freshInputs = [
    {
      name = "nixpkgs";
      lm = inputs.nixpkgs.sourceInfo.lastModified;
    }
    {
      name = "home-manager";
      lm = inputs.home-manager.sourceInfo.lastModified;
    }
  ];

  # "latest gc run" section, built at eval time from icedos.system.gc.automatic.
  # Automatic gc runs through the systemd nh-clean.timer (see modules/nh.nix). We
  # read the TIMER's LastTriggerUSec, not the service's ExecMainStartTimestamp:
  # the timer is Persistent (stamp file under /var/lib/systemd/timers), so its last
  # trigger survives reboots, whereas the service's start timestamp is in-memory
  # runtime state wiped on every boot. Read-only, no extra state. Manual `icedos
  # gc` runs are user-initiated and not systemd-tracked, hence the "automatic" label.
  gcCheck =
    if automatic then
      ''
        echo -e "${purpleString "Garbage collection"}"
        now=$(date +%s)
        last=$(${systemctl} show nh-clean.timer -p LastTriggerUSec --value --timestamp=unix 2>/dev/null)
        ts="''${last#@}"
        if [ -n "$ts" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
          age=$(((now - ts) / 86400))
          when=$(date -d "@$ts" '+%Y-%m-%d %H:%M')
          if [ "$age" -gt 30 ]; then
            warn "last automatic gc: $when (''${age}d ago) — run 'icedos gc'"
          else
            log_ok "last automatic gc: $when (''${age}d ago)"
          fi
        else
          warn "automatic gc has not run yet (scheduled: ${interval})"
        fi
        echo
      ''
    else
      ''
        echo -e "${purpleString "Garbage collection"}"
        warn "automatic gc disabled — run 'icedos gc' periodically to reclaim /nix/store"
        echo
      '';
in
{
  icedos.system.toolset.commands = [
    {
      command = "doctor";
      help = "diagnose common icedos / nix issues (health checklist)";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos doctor"
          echo "Runs a health checklist over substituters, cache keys, hardware"
          echo "config, store space, generations, gc, and input freshness."
          exit 0
        fi

        FAILS=0
        WARNS=0
        fail() {
          log_fail "$@"
          FAILS=$((FAILS + 1))
        }
        warn() {
          log_warn "$@"
          WARNS=$((WARNS + 1))
        }

        # 1. Substituters reachable -------------------------------------------
        echo -e "${purpleString "Substituters"}"
        for url in ${lib.concatMapStringsSep " " (s: "\"${s}\"") subList}; do
          if ${nixBin} --extra-experimental-features nix-command store info --store "$url" >/dev/null 2>&1; then
            log_ok "$url"
          else
            warn "$url unreachable — builds fall back to other caches / local"
          fi
        done
        echo

        # 2. Cache trust keys -------------------------------------------------
        ${lib.optionalString enable ''
          echo -e "${purpleString "Cache keys"}"
          if ${nixBin} config show trusted-public-keys 2>/dev/null | grep -qF '${key}'; then
            log_ok "icedos cache key trusted"
          else
            fail "icedos cache key not trusted — run 'icedos rebuild'"
          fi
          echo
        ''}
        # 3. Hardware configuration -------------------------------------------
        echo -e "${purpleString "Hardware"}"
        if [ -e /etc/nixos/hardware-configuration.nix ]; then
          log_ok "/etc/nixos/hardware-configuration.nix present"
        else
          warn "/etc/nixos/hardware-configuration.nix missing — if icedos.system.loadHardwareConfiguration is true (default), hardware essentials are not applied. Generate with: nixos-generate-config --show-hardware-config | sudo tee /etc/nixos/hardware-configuration.nix"
        fi
        echo

        # 4. Store space & generations ----------------------------------------
        echo -e "${purpleString "Store & generations"}"
        read -r avail usep < <(df -P /nix/store | awk 'NR==2 {gsub(/%/,"",$5); print $4, $5}')
        availg=$((avail / 1024 / 1024))
        if [ "$availg" -lt 5 ]; then
          fail "/nix/store low on space: ''${availg}G free (''${usep}% used) — run 'icedos gc'"
        elif [ "$availg" -lt 15 ]; then
          warn "/nix/store getting full: ''${availg}G free (''${usep}% used)"
        else
          log_ok "/nix/store: ''${availg}G free (''${usep}% used)"
        fi
        shopt -s nullglob
        gens=(/nix/var/nix/profiles/system-*-link)
        shopt -u nullglob
        if [ ''${#gens[@]} -gt 20 ]; then
          warn "''${#gens[@]} system generations on disk — 'icedos gc' reclaims space"
        else
          log_ok "''${#gens[@]} system generations"
        fi
        echo

        # 5. Garbage collection -----------------------------------------------
        ${gcCheck}
        # 6. Flake input freshness --------------------------------------------
        echo -e "${purpleString "Flake inputs"}"
        now=$(date +%s)
        ${lib.concatMapStrings (i: ''
          days=$(((now - ${toString i.lm}) / 86400))
          if [ "$days" -gt 90 ]; then
            warn "${i.name} is ''${days}d old — 'icedos rebuild --update'"
          elif [ "$days" -gt 30 ]; then
            warn "${i.name} is ''${days}d old"
          else
            log_ok "${i.name} fresh (''${days}d)"
          fi
        '') freshInputs}
        echo

        # Summary -------------------------------------------------------------
        if [ "$FAILS" -gt 0 ]; then
          die "$FAILS issue(s), $WARNS warning(s)"
        elif [ "$WARNS" -gt 0 ]; then
          log_warn "$WARNS warning(s), no failures"
        else
          log_ok "all checks passed"
        fi
      '';
    }
  ];
}
