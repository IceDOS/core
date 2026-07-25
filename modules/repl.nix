{
  config,
  icedosLib,
  inputs,
  pkgs,
  ...
}:

let
  inherit (icedosLib.bash) genHelpFlags;
  inherit (config.icedos) configurationLocation;

  configRoot = "${configurationLocation}/..";

  # Thin wrapper over the shared binding set (lib/repl-context.nix), which the
  # MCP server's `nix_eval` imports too — keep the names in the help text below
  # in sync with what that file returns.
  replExpr = pkgs.writeText "icedos-repl.nix" ''
    import "${inputs.icedos-core}/lib/repl-context.nix" {
      configRoot = "${configRoot}";
      stateDir = "${configurationLocation}";
    }
  '';
in
{
  icedos.system.toolset.commands = [
    {
      command = "repl";
      help = "nix repl preloaded with the evaluated icedos config, packages, and lib";

      script = ''
        if [[ ${genHelpFlags { excludeNoArgs = true; }} ]]; then
          echo "Usage: icedos repl"
          echo "Opens a nix repl with the icedos configuration preloaded."
          echo
          echo "Bindings:"
          echo "  config     evaluated config of the running system, module defaults included"
          echo "  options    option declarations — type, default, description"
          echo "  declared   raw config.toml merge from the working tree (your pending changes)"
          echo "  pkgs       the system's nixpkgs, with its overlays and nixpkgs.config"
          echo "  lib        nixpkgs lib"
          echo "  icedosLib  icedos helper library"
          echo "  inputs     resolved flake inputs"
          exit 0
        fi

        if [ ! -f "${configurationLocation}/flake.nix" ]; then
          die "no generated flake at '${configurationLocation}'; run 'icedos rebuild' once."
        fi

        exec nix repl --file ${replExpr}
      '';
    }
  ];
}
