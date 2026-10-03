{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    claude-code
    gh
  ];
}
