{ pkgs, ... }:

{
  environment.systemPackages = [
    pkgs.nvtopPackages.nvidia
  ];
}
