{
  config,
  icedosLib,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash) configSet genHelpFlags purpleString;

  inherit (config.icedos) configurationLocation;
  inherit (config.icedos.system.gc) automatic interval;
  inherit (config.icedos.system.cache) enable key;

  jq = "${pkgs.jq}/bin/jq";
  systemctl = "${pkgs.systemd}/bin/systemctl";
  nixBin = "${config.nix.package}/bin/nix";

  subList = with config.nix.settings; substituters ++ trusted-substituters;

  cacheDir = "${configurationLocation}/.cache";
  modulesCache = "${cacheDir}/modules-doc.json";

  inherit (configSet config) configRoot walk;

  freshInputs = icedosLib.freshInputs inputs;

  gcStatusScript =
    if automatic then
      ''
        ${icedosLib.bash.gcTimerCheckSnippet { inherit systemctl; }}
        if [ -n "$gc_age" ]; then
          if [ "$gc_age" -gt 30 ]; then
            chk_warn "auto (${interval}) | last: $gc_dt (''${gc_age}d ago)"
          else
            chk_ok "auto (${interval}) | last: $gc_dt (''${gc_age}d ago)"
          fi
        else
          chk_warn "auto (${interval}) | not yet run"
        fi
      ''
    else
      ''
        chk_warn "disabled — run icedos gc periodically"
      '';
in
{
  icedos.system.toolset.commands = [
    {
      command = "status";
      help = "system dashboard - generation, store, modules, inputs, and health checks";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos status"
          echo "One-screen system dashboard: generation, store, gc, modules,"
          echo "input freshness, pending changes, and health checks"
          echo "(substituters, cache trust, hardware config)."
          exit 0
        fi

        [ "$#" -gt 0 ] && die "unknown arg: $1"

        now=$(date +%s)

        ${walk}

        FAILS=0
        WARNS=0
        chk_ok()   { printf '  %b✓%b %s\n' "$GREEN"   "$NC" "$*"; }
        chk_warn() { printf '  %b⚠%b %s\n' "$YELLOW"  "$NC" "$*"; WARNS=$((WARNS + 1)); }
        chk_fail() { printf '  %b✗%b %s\n' "$RED"     "$NC" "$*"; FAILS=$((FAILS + 1)); }

        echo -e "${purpleString "System"}"
        hostname=$(uname -n 2>/dev/null || echo "?")
        kernel=$(uname -r 2>/dev/null || echo "?")
        read -r uptime_secs _ < /proc/uptime
        uptime_secs=''${uptime_secs%.*}
        uptime_days=$((uptime_secs / 86400))
        uptime_hours=$(((uptime_secs % 86400) / 3600))
        uptime_mins=$(((uptime_secs % 3600) / 60))
        if [ "$uptime_days" -gt 0 ]; then
          uptime_str="''${uptime_days}d ''${uptime_hours}h ''${uptime_mins}m"
        else
          uptime_str="''${uptime_hours}h ''${uptime_mins}m"
        fi
        printf '  hostname  %s\n' "$hostname"
        printf '  kernel    %s\n' "$kernel"
        printf '  uptime    %s\n' "$uptime_str"

        echo -e "\n${purpleString "Build"}"
        current_link="/nix/var/nix/profiles/system"
        current="$(basename "$(readlink "$current_link" 2>/dev/null)" | sed 's/^system-\([0-9]*\)-link$/\1/')"
        if [ -n "$current" ]; then
          m="$(stat -c %Y "/nix/var/nix/profiles/system-''${current}-link" 2>/dev/null || echo 0)"
          age=$(((now - m) / 86400))
          dt="$(date -d "@$m" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")"
          printf '  gen #%s  %s  %sd ago\n' "$current" "$dt" "$age"
        else
          printf '  no system generation found\n'
        fi

        echo -e "\n${purpleString "Store"}"
        read -r avail usep < <(df -P /nix/store 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $4, $5}')
        if [ -n "$avail" ]; then
          availg=$((avail / 1024 / 1024))
          if [ "$availg" -lt 5 ]; then
            chk_fail "''${availg}G free (''${usep}% used) — low space! run 'icedos gc'"
          elif [ "$availg" -lt 15 ]; then
            chk_warn "''${availg}G free (''${usep}% used)"
          else
            chk_ok "''${availg}G free (''${usep}% used)"
          fi
        else
          chk_fail "/nix/store unreachable"
        fi
        shopt -s nullglob
        gens=(/nix/var/nix/profiles/system-*-link)
        shopt -u nullglob
        if [ ''${#gens[@]} -gt 20 ]; then
          chk_warn "''${#gens[@]} generations on disk — 'icedos gc' reclaims space"
        else
          chk_ok "''${#gens[@]} generations on disk"
        fi

        echo -e "\n${purpleString "Garbage collection"}"
        ${gcStatusScript}

        echo -e "\n${purpleString "Modules"}"
        if [ -f "${modulesCache}" ]; then
          total=$(${jq} length "${modulesCache}" 2>/dev/null || echo 0)
          enabled=$(${jq} '[.[] | select(.enabled)] | length' "${modulesCache}" 2>/dev/null || echo 0)
          explicit=$(${jq} '[.[] | select(.explicit == true)] | length' "${modulesCache}" 2>/dev/null || echo 0)
          transitive=$((enabled - explicit))
          available=$((total - enabled))
          printf '  %d enabled (%d explicit, %d transitive), %d available\n' "$enabled" "$explicit" "$transitive" "$available"
          stale=0
          for src in "${configRoot}/config.toml" "${configurationLocation}/flake.lock"; do
            [ -f "$src" ] && [ "$src" -nt "${modulesCache}" ] && stale=1
          done
          shopt -s nullglob
          for d in "''${CONFIG_DIRS[@]}"; do
            for src in "${configRoot}/$d/"*.toml "${configRoot}/$d/".*.toml; do
              [ -f "$src" ] && [ "$src" -nt "${modulesCache}" ] && stale=1
            done
          done
          shopt -u nullglob
          if [ "$stale" -eq 1 ]; then
            chk_warn "index stale — run 'icedos configuration refresh'"
          fi
        else
          chk_warn "index not ready — run 'icedos configuration refresh'"
        fi

        echo -e "\n${purpleString "Inputs"}"
        ${lib.concatMapStrings (i: ''
          days=$(((now - ${toString i.lm}) / 86400))
          if [ "$days" -gt 90 ]; then
            chk_warn "${i.name} ''${days}d old — run 'icedos rebuild --update'"
          elif [ "$days" -gt 30 ]; then
            chk_warn "${i.name} ''${days}d old"
          else
            chk_ok "${i.name} ''${days}d fresh"
          fi
        '') freshInputs}

        echo -e "\n${purpleString "Pending"}"
        shopt -s nullglob
        latest=""
        for d in "${cacheDir}"/*/; do
          [ -f "''${d}.config-set" ] && latest="$d"
        done
        shopt -u nullglob

        if [ -n "$latest" ]; then
          differs=0
          diff_pair() {
            local label="$1" snap="$2" work="$3"
            [ -f "$snap" ] || snap=/dev/null
            [ -f "$work" ] || work=/dev/null
            if ! diff -q "$snap" "$work" >/dev/null 2>&1; then
              differs=1
            fi
          }
          walk_config_set "$latest" diff_pair

          if [ "$differs" -eq 1 ]; then
            chk_warn "config differs from last build — run icedos configuration diff"
          else
            chk_ok "no changes since last build"
          fi
        else
          chk_warn "no config snapshot yet — run icedos rebuild"
        fi

        echo -e "\n${purpleString "Substituters"}"
        for url in ${lib.concatMapStringsSep " " (s: "\"${s}\"") subList}; do
          if ${nixBin} --extra-experimental-features nix-command store info --store "$url" >/dev/null 2>&1; then
            chk_ok "$url"
          else
            chk_warn "$url unreachable — builds fall back to other caches / local"
          fi
        done

        ${lib.optionalString enable ''
          echo -e "\n${purpleString "Cache"}"
          if ${nixBin} config show trusted-public-keys 2>/dev/null | grep -qF '${key}'; then
            chk_ok "icedos cache key trusted"
          else
            chk_fail "icedos cache key not trusted — run 'icedos rebuild'"
          fi
        ''}

        echo -e "\n${purpleString "Hardware"}"
        if [ -e /etc/nixos/hardware-configuration.nix ]; then
          chk_ok "/etc/nixos/hardware-configuration.nix present"
        else
          chk_warn "/etc/nixos/hardware-configuration.nix missing — if icedos.system.loadHardwareConfiguration is true (default), hardware essentials are not applied. Generate with: nixos-generate-config --show-hardware-config | sudo tee /etc/nixos/hardware-configuration.nix"
        fi

        echo -e "\n${purpleString "Summary"}"
        if [ "$FAILS" -gt 0 ]; then
          chk_fail "$FAILS issue(s), $WARNS warning(s)"
          exit 1
        elif [ "$WARNS" -gt 0 ]; then
          printf '  %b⚠%b %s warning(s), no failures\n' "$YELLOW" "$NC" "$WARNS"
        else
          chk_ok "all checks passed"
        fi
      '';
    }
  ];
}
