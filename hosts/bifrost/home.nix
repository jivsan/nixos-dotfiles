{ config, pkgs, inputs, ... }:
{
  home.stateVersion = "25.11";

  imports = [
    ../../modules/home/git.nix
    ../../modules/home/shell.nix       # your pink/cyan PS1 + fastfetch
    ./modules/home/terminal.nix        # alacritty (themed, runs on Wayland)
    ../../modules/home/neovim.nix      # nvim + lua-language-server (LSP for hyprland.lua)
    ../../modules/home/xdg.nix         # symlinks your nvim config from the repo
    ./modules/home/hyprland.nix        # bifrost-local: Wayland userland + the lua config

    # Intentionally skipped:
    #   programs.nix  -> pulls X11 rofi + Talos/k8s tooling; we use rofi-wayland instead
    #   suckless/picom/gtk -> X11 / oxwm only
  ];
}
