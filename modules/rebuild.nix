{
  config,
  icedosLib,
  lib,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash)
    dimGreenString
    genHelpFlags
    prelude
    redString
    requireConfigOwner
    ;

  inherit (lib) genAttrs imap0;

  inherit (config) icedos;
  inherit (icedos) configurationLocation;
  inherit (icedos.system.toolset.rebuild) hooks;

  # One script per hook, so each runs in a fresh shell (isolated env/traps/exit)
  # with the prelude available.
  hookScripts =
    name:
    imap0 (
      i: s: "${pkgs.writeShellScript "icedos-hook-${name}-${toString i}" "${prelude}\n${s}"}"
    ) hooks.${name};

  # Read by build/context.py. Only ever add keys, because a newer core must
  # still read the file an older system hands it.
  rebuildContext = pkgs.writeText "icedos-rebuild-context.json" (
    builtins.toJSON {
      version = 1;
      configDirs = icedos.system.extraConfigs;
      hooks = genAttrs [
        "preRebuild"
        "postRebuild"
        "preUpdate"
        "postUpdate"
      ] hookScripts;
    }
  );
in
{
  icedos.system.toolset.commands = [
    {
      command = "rebuild";
      help = "rebuild the system";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          cat ${../build/usage.txt}
          exit 0
        fi

        ORIG_ARGS=("$@")
        ${requireConfigOwner}

        # Only --dir belongs to the shim; build/options.py parses everything else.
        REBUILD_DIR=""
        args=()
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --dir)
              [[ $# -ge 2 ]] || die "--dir requires a directory"
              REBUILD_DIR="$2"
              shift 2
              ;;
            # The rest of the line belongs to nh or nix, even a literal --dir.
            --nh-args|--build-args)
              args+=("$@")
              break
              ;;
            *)
              args+=("$1")
              shift
              ;;
          esac
        done

        # Resolve the token before any nix call: a stale lock makes `nix run` hit
        # the GitHub API before the orchestrator can set NIX_CONFIG itself.
        tokenFile="''${ICEDOS_GITHUB_TOKEN_PATH:-${icedosLib.GITHUB_TOKEN_PATH}}"
        tokenEnv=()
        if [ -z "''${ICEDOS_GITHUB_TOKEN:-}" ] && [ -f "$tokenFile" ]; then
          token="$(cat "$tokenFile" 2>/dev/null || sudo -n cat "$tokenFile" 2>/dev/null || true)"
          if [ -z "$token" ] && [ -t 0 ]; then
            token="$(sudo cat "$tokenFile" 2>/dev/null)" || true
          fi
          if [ -n "$token" ]; then
            # Prefixed onto each build invocation, never exported: hooks are
            # user-authored scripts and must not inherit a live credential.
            tokenEnv=(
              "ICEDOS_GITHUB_TOKEN=$token"
              "NIX_CONFIG=''${NIX_CONFIG:+"$NIX_CONFIG
        "}access-tokens = github.com=$token"
            )
          else
            log_warn "cannot read $tokenFile; github api calls will be unauthenticated"
          fi
        fi

        # Exit 130 = interrupted. The orchestrator already reported which
        # phase it died in, and whether activation could have started.
        exit_if_interrupted() {
          if [ "$1" -eq 130 ]; then
            log_warn "rebuild interrupted — rerun to resume"
            exit 130
          fi
        }

        if [ -n "$REBUILD_DIR" ]; then
          if [ ! -d "$REBUILD_DIR" ]; then
            echo -e "${redString "error"}: directory '$REBUILD_DIR' does not exist"
            exit 1
          fi
          if [ ! -f "$REBUILD_DIR/flake.nix" ]; then
            echo -e "${redString "error"}: no flake.nix found in '$REBUILD_DIR'"
            exit 1
          fi
          cd "$REBUILD_DIR"
          env "''${tokenEnv[@]}" nix run path:. -- "''${args[@]}"
          rc=$?
          exit_if_interrupted "$rc"
          exit "$rc"
        fi

        require_config_owner "${configurationLocation}/.." "${configurationLocation}" "''${ORIG_ARGS[@]}"

        if [ ! -d "${configurationLocation}" ]; then
          if [ -n "''${ICEDOS_OWNER_DECLINED:-}" ]; then
            die "no permission to access configuration path '${configurationLocation}'; run it as the owning user or fix the permissions."
          fi
          printf -v PROMPT '%b' "${dimGreenString ">"} Configuration location (${configurationLocation}) does not exist. Use current directory ($PWD)? [y/N] "
          read -r -p "$PROMPT" ANSWER
          case "$ANSWER" in
            [yY]|[yY][eE][sS]) ;;
            *)
              echo -e "${redString "error"}: configuration path is invalid, execute 'nix run .' inside the configuration directory to update the path."
              exit 1
              ;;
          esac
          env "''${tokenEnv[@]}" nix run path:. -- "''${args[@]}"
          rc=$?
          exit_if_interrupted "$rc"
          exit "$rc"
        fi

        cd "${configurationLocation}" || die "no permission to enter '${configurationLocation}'; run it as the owning user or fix the permissions."

        # build/ runs the hooks, snapshot and reboot check from this context, and
        # gives hooks the ICEDOS_ORIG_* values instead of the build PATH or token.
        env "''${tokenEnv[@]}" \
          ICEDOS_REBUILD_CONTEXT=${rebuildContext} \
          ICEDOS_ORIG_PATH="$PATH" \
          ICEDOS_ORIG_NIX_CONFIG="''${NIX_CONFIG-}" \
          ICEDOS_ORIG_PYTHONPATH="''${PYTHONPATH-}" \
          bash ./build.sh "''${args[@]}"
        rc=$?
        exit_if_interrupted "$rc"
        exit "$rc"
      '';
    }
  ];

  icedos.system.tips.list = [
    "icedos rebuild --dry prepares a rebuild without building anything."
    "icedos rebuild --update gets the newest packages, repos and inputs before rebuilding."
  ];
}
