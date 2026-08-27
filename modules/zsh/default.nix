{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.icedos.system.zsh) aliases enable;
  inherit (lib) mkIf readFile replaceStrings;

  # stylix is desktop-only; skip color patching and use native p10k colors.
  stylixColors = if config.lib ? stylix then config.lib.stylix.colors else null;

  p10kColorTargets = [
    "local red='#FF5C57'"
    "local yellow='#F3F99D'"
    "local blue='#57C7FF'"
    "local magenta='#FF6AC1'"
    "local cyan='#9AEDFE'"
    "local white='#F1F1F0'"
  ];

  # base16 slots: 08 red, 0A yellow, 0D blue, 0E magenta, 0C cyan, 07 white.
  p10kColorReplacements = [
    "local red='#${stylixColors.base08}'"
    "local yellow='#${stylixColors.base0A}'"
    "local blue='#${stylixColors.base0D}'"
    "local magenta='#${stylixColors.base0E}'"
    "local cyan='#${stylixColors.base0C}'"
    "local white='#${stylixColors.base07}'"
  ];

  p10kThemeText =
    if stylixColors == null then
      readFile ./p10k-theme.zsh
    else
      replaceStrings p10kColorTargets p10kColorReplacements (readFile ./p10k-theme.zsh);
in
{
  config = mkIf enable {
    fonts.packages = with pkgs; [ meslo-lgs-nf ];

    home-manager.sharedModules = [
      (
        { config, ... }:
        {
          programs.zsh = {
            enable = true;
            dotDir = "${config.xdg.configHome}/zsh";
          };

          xdg.configFile = {
            "zsh/p10k.zsh".source = "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
            "zsh/p10k-theme.zsh".text = p10kThemeText;
          };
        }
      )
    ];

    programs.zsh = {
      enable = true;

      ohMyZsh = {
        enable = true;
        plugins = [
          "git"
          "npm"
          "sudo"
          "systemd"
        ];
      };

      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;

      interactiveShellInit = ''
        if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
          source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
        fi

        [[ ! -f "''${XDG_CONFIG_HOME:-$HOME/.config}/zsh/p10k.zsh" ]] || source "''${XDG_CONFIG_HOME:-$HOME/.config}/zsh/p10k.zsh"
        [[ ! -f "''${XDG_CONFIG_HOME:-$HOME/.config}/zsh/p10k-theme.zsh" ]] || source "''${XDG_CONFIG_HOME:-$HOME/.config}/zsh/p10k-theme.zsh"
        unsetopt PROMPT_SP
      '';

      shellAliases = aliases;
    };

    users.defaultUserShell = pkgs.zsh;
  };
}
