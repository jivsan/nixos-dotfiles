{ pkgs, ... }:
{
  programs.vscodium.enable = true;

  home.packages = with pkgs; [
    gcc
    rofi
    feh
    kubectl
    talosctl
    fluxcd
    kubernetes-helm
    kustomize
    kubeseal
    rsync
  ];
}
