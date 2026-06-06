{ pkgs, ... }:
{
  programs.bash = {
    enable = true;
    shellAliases = {
      btw = "echo i use nixos, btw";
    };
    initExtra = ''
      PS1='\[\e[38;2;255;79;163m\][\u@\h:\[\e[38;2;45;226;230m\]\w\[\e[38;2;255;79;163m\]]\$\[\e[0m\] '
      export TALOSCONFIG=$HOME/talos-cluster/talosconfig
      fastfetch
    '';
  };

  home.packages = [ pkgs.fastfetch ];
}
